import Config

# Vazio de propósito.
#
# Toda a configuração deste projeto é lida de variáveis de ambiente em
# `Rinha.Config`, no início da aplicação, e guardada em `:persistent_term`.
# Usar `Application.put_env` aqui funcionaria, mas `Application.get_env` no
# caminho quente é uma busca em ETS por requisição — `:persistent_term` é uma
# leitura sem cópia e sem lock.
