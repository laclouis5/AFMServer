import Vapor
import FoundationModels

struct AFMInputMessage: Content {
    let role: String
    let content: String
}

enum AFMInput: Content {
    case string(String)
    case list([AFMInputMessage])
    
    init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()

            if let text = try? container.decode(String.self) {
                self = .string(text)
                return
            }

            if let messages = try? container.decode([AFMInputMessage].self) {
                self = .list(messages)
                return
            }

            throw DecodingError.typeMismatch(
                AFMInput.self,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: #"Expected a String or an array of {"role": ..., "content": ...} for `input`"#,
                )
            )
        }
}

extension Optional where Wrapped == AFMInput {
    func transcript(instructions: String?) throws -> (Transcript, Prompt) {
        var entries = [Transcript.Entry]()
        let prompt: Prompt
        
        if let instructions {
            entries.append(.instructions(.init(segments: [.text(.init(content: instructions))], toolDefinitions: [])))
        }
        
        switch self {
        case let .string(input):
            prompt = Prompt(input)
        case let .list(inputs):
            guard let lastItem = inputs.last, lastItem.role == "user" else {
                throw Abort(.badRequest, reason: "Malformed input")
            }
            
            prompt = Prompt(lastItem.content)
            let items = inputs[..<(inputs.endIndex - 1)]
            
            for item in items {
                switch item.role {
                case "developer":
                    entries.append(.instructions(.init(segments: [.text(.init(content: item.content))], toolDefinitions: [])))
                case "user":
                    entries.append(.prompt(.init(segments: [.text(.init(content: item.content))])))
                case "assistant":
                    entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: item.content))])))
                default:
                    throw Abort(.badRequest, reason: "Malformed input")
                }
            }
        case .none:
            prompt = Prompt("")
        }
        
        return (Transcript(entries: entries), prompt)
    }
}

struct AFMCreateResponse: Content {
    let model: String?
    let input: AFMInput?
    let instructions: String?
    let max_output_tokens: Int?
    let stream: Bool?
    let temperature: Double?
}

struct AFMContent: Content {
    let type: String
    let text: String
}

struct AFMOutput: Content {
    let id: UUID
    let type: String
    let status: String
    let role: String
    let content: [AFMContent]
}

struct AFMResponse: Content {
    let id: UUID
    let object: String
    let created_at: Int
    let status: String
    let output: [AFMOutput]
    let output_text: String?
}

struct AFMSSEResponse: Content {
    let type: String
    let response: AFMResponse
}

struct AFMOutputTextDelta: Content {
    let type: String
    let delta: String
}

struct AFMOutputTextDone: Content {
    let type: String
    let text: String
}

struct AFMResponseCompleted: Content {
    let type: String
    let response: AFMResponse
}

func encodeSSE(content: some Content, jsonEncoder: JSONEncoder) throws -> ByteBuffer {
    var data = "data: ".data(using: .utf8)!
    try data.append(jsonEncoder.encode((content)))
    data.append("\n\n".data(using: .utf8)!)
    return ByteBuffer(data: data)
}

func respond(
    response: AFMCreateResponse,
    req: Request
) async throws -> Response {
    let (transcript, prompt) = try response.input.transcript(instructions: response.instructions)
    let session = LanguageModelSession(model: .default, transcript: transcript)

    let modelResponse = try await session.respond(
        to: prompt,
        options: GenerationOptions(
            temperature: response.temperature,
            maximumResponseTokens: response.max_output_tokens,
        )
    ).content
    
    req.logger.info("Model response done: \(session.transcript)")
    
    let content = AFMContent(
        type: "output_text",
        text: modelResponse,
    )
    
    let output = AFMOutput(
        id: UUID(),
        type: "message",
        status: "completed",
        role: "assistant",
        content: [content],
    )
    
    let response = AFMResponse(
        id: UUID(),
        object: "response",
        created_at: Int(Date().timeIntervalSince1970),
        status: "completed",
        output: [output],
        output_text: modelResponse,
    )
    
    return try Response(status: .ok, body: .init(buffer: ByteBuffer(data: JSONEncoder().encode(response))))
}

func streamRespond(
    response: AFMCreateResponse,
    req: Request
) async throws -> Response {
    let jsonEncoder = JSONEncoder()
    
    let body = Response.Body(asyncStream: { writer in
        do {
            let (transcript, prompt) = try response.input.transcript(instructions: response.instructions)
            let session = LanguageModelSession(model: .default, transcript: transcript)
            
            let responseStream = session.streamResponse(
                to: prompt,
                options: GenerationOptions(
                    temperature: response.temperature,
                    maximumResponseTokens: response.max_output_tokens,
                )
            )
            
            req.logger.info("Response stream init")
            
            let creationTime = Int(Date().timeIntervalSince1970)
            let responseId = UUID()
            
            let respCreated = AFMSSEResponse(
                type: "response.created",
                response: AFMResponse(
                    id: responseId,
                    object: "response",
                    created_at: creationTime,
                    status: "in_progress",
                    output: [],
                    output_text: nil,
                ),
            )
            
            let respCreatedBuffer = try encodeSSE(content: respCreated, jsonEncoder: jsonEncoder)
            try await writer.writeBuffer(respCreatedBuffer)
            req.logger.info("Response Creation Event Sent")
            
            var deltaStartIndex =  "".startIndex
            
            for try await tokens in responseStream {
                let partialContent = tokens.content
                let delta = String(partialContent[deltaStartIndex...])
                deltaStartIndex = partialContent.endIndex
                
                let outputTextDelta = AFMOutputTextDelta(type: "response.output_text.delta", delta: delta)
                let outputTextDeltaBuffer = try encodeSSE(content: outputTextDelta, jsonEncoder: jsonEncoder)
                try await writer.writeBuffer(outputTextDeltaBuffer)
                req.logger.info("Text Delta Event Sent")
            }
            
            let modelResponse = try await responseStream.collect().content
            
            let outputItem = AFMOutput(
                id: UUID(),
                type: "message",
                status: "completed",
                role: "assistant",
                content: [
                    AFMContent(type: "output_text", text: modelResponse)
                ]
            )
            
            let respCompleted = AFMSSEResponse(
                type: "response.completed",
                response: AFMResponse(
                    id: responseId,
                    object: "response",
                    created_at: creationTime,
                    status: "completed",
                    output: [outputItem],
                    output_text: modelResponse,
                ),
            )
            
            let respCompletedBuffer = try encodeSSE(content: respCompleted, jsonEncoder: jsonEncoder)
            try await writer.writeBuffer(respCompletedBuffer)
            req.logger.info("Response Completed Event Sent")
            
            try await writer.write(.end)
            req.logger.info("End Event Sent")
        } catch {
            try await writer.write(.error(error))
            req.logger.error("Error while generating stream response: \(error)")
        }
    })
    
    let response = Response(status: .ok, body: body)
    
    response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
    response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
    response.headers.replaceOrAdd(name: .connection, value: "keep-alive")

    return response
}

func routes(_ app: Application) async throws {
    app.group("v1") { v1 in
        v1.group("responses") { responses in
            responses.post { (req: Request) -> Response in
                let response = try req.content.decode(AFMCreateResponse.self)
                req.logger.info("Decoded create response")
                
                if response.model != "apple-fm-default" {
                    throw Abort(.badRequest, reason: "Model does not exist")
                }
                
                switch response.stream {
                case nil, false:
                    return try await respond(response: response, req: req)
                case true:
                    return try await streamRespond(response: response, req: req)
                }
            }
        }
    }
}
