# The Sapira collector for hermes-agent-service.
#
# The image is upstream's; this repo adds one file. Pinned rather than :latest for the reason
# ENG-STD-0021 §9 gives: a deployment that floats cannot be inventoried, and "which collector was
# running when the spans went missing" is a question with no answer if the tag moves.
FROM otel/opentelemetry-collector-contrib:0.160.0

COPY config.yaml /etc/otelcol-contrib/config.yaml

# 4317 gRPC · 4318 HTTP · 13133 health. None are published to the internet: Hermes reaches the
# collector over Railway's private network, and nothing outside the project needs to.
EXPOSE 4317 4318 13133
