# TICKET-012: OpenAPI Spec Validation Testing

**Status:** Open
**Priority:** P2 (API correctness proof)
**Blocked by:** Nothing

---

## Goal

Validate apfel server responses against OpenAI's official OpenAPI specification.
Proves compatibility at the schema level, not just "it works with the Python client."

## Approach

OpenAI publishes their official OpenAPI 3.1 spec at:
https://github.com/openai/openai-openapi

Use `openapi-core` (Python) to validate that every response from apfel conforms
to the `CreateChatCompletionResponse` and `CreateChatCompletionStreamResponse` schemas.

## Implementation

```python
# pip install openapi-core pyyaml httpx
from openapi_core import OpenAPI

openapi = OpenAPI.from_file_path("openai-openapi.yaml")
# Send requests to apfel, validate responses against spec
openapi.validate_response(request, response)
```

Add to `Tests/integration/openapi_spec_test.py`.

## References

- Official spec: https://github.com/openai/openai-openapi
- openapi-core: https://pypi.org/project/openapi-core/
