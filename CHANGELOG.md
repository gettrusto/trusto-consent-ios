# Changelog

## 0.1.0

Primeira versão, modo sem tela (ADR 0135, M2).

- `configure(publishableKey:endpoint:)` e `shared`, com a chave publicável conferida no aparelho
- `loadConfig()`: banner publicado do aplicativo, com cache de 60 s e o último guardado quando não há rede
- `acceptAll()`, `rejectAll()`, `save(categories:)` e `revoke()`, com as mesmas regras de decisão do coletor
- `decision`, `needsConsent`, `isGranted(_:)` e `observe(on:_:)` para ligar e desligar SDKs de terceiros
- Fila persistida com reenvio e espera crescente até 1 h, no máximo 50 decisões e 30 dias; `flush()`
- Identificador do visitante aleatório no Keychain do aparelho
