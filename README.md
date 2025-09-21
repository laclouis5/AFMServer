# AFMServer

An Apple Foundation Models server with an OpenAI-like API.

## Getting Started

To start the server, use the following command:

```bash
swift run
```

Then, make a request using the OpenAI API:

```bash
 curl http://localhost:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"apple-fm-default\",
    \"instructions\": \"Be short and concise.\",
    \"input\": \"How to solve a Rubik'ss Cube?\"
}"
```

Or with the Python OpenAI library:

```python
client = OpenAI(api_key="fake-api-key", base_url="http://127.0.0.1:8080/v1")

response = client.responses.create(
    model="apple-fm-default",
    instructions="Be short and concise.",
    input="How to solve a Rubik's cube?",
)

print(response.output_text)
```
