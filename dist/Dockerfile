# The agentos-dist Girder worker (dist/mirror.py). Built from the repo root: girder app_config dockerfile=dist/Dockerfile.
FROM python:3.13-slim@sha256:2d44738ebf4ce5f63b9d9ea871e9c7cfdc0426f7b0c97cac915fd88ded1d86bb
COPY dist/requirements.txt /app/requirements.txt
# pip (and its vendored urllib3) and setuptools are only needed to install: remove them so the
# running image carries nothing the mirror doesn't use (the image scan flagged their old copies).
RUN pip install --no-cache-dir --root-user-action=ignore --require-hashes -r /app/requirements.txt && \
    pip uninstall -y -q --root-user-action=ignore pip setuptools wheel 2>/dev/null; \
    rm -rf /usr/local/lib/python3.13/ensurepip
COPY dist/mirror.py /app/mirror.py
USER 65534
CMD ["python", "-u", "/app/mirror.py"]
