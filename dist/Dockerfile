# The agentos-dist Girder worker (dist/mirror.py). Built from the repo root: girder app_config dockerfile=dist/Dockerfile.
FROM python:3.13-slim@sha256:2d44738ebf4ce5f63b9d9ea871e9c7cfdc0426f7b0c97cac915fd88ded1d86bb
COPY dist/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --root-user-action=ignore --require-hashes -r /app/requirements.txt
COPY dist/mirror.py /app/mirror.py
USER 65534
CMD ["python", "-u", "/app/mirror.py"]
