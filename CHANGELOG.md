# Changelog

## 0.1.0

Primeira versão, modo sem tela.

- `configure(publishableKey:endpoint:)` e `shared`, com a chave publicável conferida no aparelho
- `loadConfig()`: banner publicado do aplicativo, com cache de 60 s e o último guardado quando não há rede
- `acceptAll()`, `rejectAll()`, `save(categories:)` e `revoke()`, com as mesmas regras de decisão do coletor
- `decision`, `needsConsent`, `isGranted(_:)` e `observe(on:_:)` para ligar e desligar SDKs de terceiros
- Fila persistida e em ordem, com reenvio automático e espera crescente até 1 h, no máximo 50 decisões e 30 dias; chave recusada ou rota fora do ar esperam 1 h, sem perder a prova; `flush()`
- Identificador do visitante aleatório no Keychain do aparelho; com o Keychain indisponível, o envio espera
- Banner, decisão e fila separados por ambiente da chave: trocar de teste para produção (ou o contrário) na mesma instalação descarta o que veio do outro; trocar de coletor descarta só o banner em cache; a rotação da chave mantém tudo
- Endereço do coletor só `https`, corpo da resposta com teto de 256 KB, arquivos com versão de formato
