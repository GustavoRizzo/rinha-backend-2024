import Config

# Log só a partir de `warning`, e sem metadados. Mesma decisão do `--log-level
# warning --no-access-log` do uvicorn e do `access_log off` do nginx: log por
# requisição é I/O no caminho quente (medido em `performance/django/01`).
config :logger, level: :warning

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"
