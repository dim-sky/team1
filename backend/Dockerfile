FROM python:3.13-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy

# Install dependencies first (cached unless pyproject/lock change)
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-install-project --no-dev

# Copy the source and install the project itself
COPY README.md ./
COPY src ./src
RUN uv sync --locked --no-dev

ENV PATH="/app/.venv/bin:$PATH"
EXPOSE 8000

CMD ["uvicorn", "myserver.server:server", "--host", "0.0.0.0", "--port", "8000"]