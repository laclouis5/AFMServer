import Vapor
import FoundationModels

struct AFMCreateResponse: Content {
    let model: String?
    let input: String?
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
    session: LanguageModelSession,
    response: AFMCreateResponse,
    req: Request
) async throws -> Response {
    let modelResponse = try await session.respond(
        to: response.input ?? "",
        options: GenerationOptions(
            temperature: response.temperature,
            maximumResponseTokens: response.max_output_tokens,
        )
    ).content
    
    req.logger.info("Model response done")
    
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
    session: LanguageModelSession,
    response: AFMCreateResponse,
    req: Request
) async throws -> Response {
    let jsonEncoder = JSONEncoder()
    
    let body = Response.Body(asyncStream: { writer in
        do {
            let responseStream = session.streamResponse(
                to: response.input ?? "",
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
                
                let session = LanguageModelSession(model: .default, instructions: response.instructions)
                
                switch response.stream {
                case nil, false:
                    return try await respond(session: session, response: response, req: req)
                case true:
                    return try await streamRespond(session: session, response: response, req: req)
                }
            }
        }
    }
}
