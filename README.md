# TrustoConsent para iOS

SDK de consentimento da Trusto para aplicativos iOS. Registra no aplicativo o consentimento das pessoas com a mesma prova que o banner registra no site: qual banner a pessoa viu, o que decidiu e quando.

Versão 0.1.0, **modo sem tela**: o aplicativo desenha a própria tela de consentimento, e o SDK busca o banner publicado, guarda a decisão no aparelho, avisa o aplicativo quando ela muda e grava a prova, com reenvio quando o aparelho estiver sem rede. A tela pronta vem numa versão seguinte.

## Antes de começar

1. No painel da Trusto, em **Consentimentos > Aplicativos**, cadastre o aplicativo com o Team ID e o Bundle ID
2. Publique o arquivo `/.well-known/apple-app-site-association` que a tela mostra, no domínio verificado escolhido
3. Com a posse verificada, gere a **chave publicável** (`trusto_pk_live_…`). Ela não é segredo: só grava decisões deste aplicativo e lê o banner publicado dele, por isso pode ir dentro do aplicativo

O aplicativo usa o banner publicado do domínio da posse: as finalidades e os textos são os mesmos do site.

## Instalação

Swift Package Manager, iOS 15 ou mais recente, sem nenhuma dependência além da plataforma. No Xcode, em **File > Add Package Dependencies**, informe o endereço do repositório e escolha o produto `TrustoConsent`. Num `Package.swift`:

```swift
.package(url: "<endereço do repositório>", from: "0.1.0")
```

## Uso

```swift
import TrustoConsent

// No início do app, uma vez.
try TrustoConsent.configure(publishableKey: "trusto_pk_live_...")

let consent = TrustoConsent.shared

// O banner publicado: finalidades, textos, link da política e cores da empresa.
let config = try await consent.loadConfig()

if consent.needsConsent {
    // Mostre a sua tela com config.categories e grave a escolha:
    try await consent.acceptAll()
    // ou: try await consent.rejectAll()
    // ou: try await consent.save(categories: ["analytics": true, "marketing": false])
}

// Ligue ou desligue os SDKs de terceiros conforme a decisão, agora e a cada mudança.
let observation = consent.observe { decision in
    analytics.setEnabled(consent.isGranted("analytics"))
}

// Revogar também é gravado como prova.
try await consent.revoke()
```

- `needsConsent` é verdadeiro sem decisão, quando a decisão é de outra versão do banner ou quando venceu
- `isGranted(_:)` diz se a finalidade está concedida agora; sem decisão, nenhuma está
- A decisão vale no aparelho na hora, antes de chegar à Trusto. Sem rede, ela fica numa fila e é reenviada; chame `flush()` quando o app voltar ao primeiro plano
- Em `save(categories:)`, finalidade opcional não informada fica recusada, e recusar uma obrigatória é erro
- Para testar em staging, passe o endereço de staging em `configure(publishableKey:endpoint:)` com a chave `trusto_pk_test_…`

## Responsabilidade de quem desenha a própria tela

No modo sem tela, a empresa responde por pedir o consentimento como a LGPD exige: finalidades claras e com os textos do banner publicado, recusar tão fácil quanto aceitar, nenhuma finalidade opcional marcada de antemão e nada que dependa de consentimento ligado antes da decisão. O SDK confere a coerência da decisão com o banner, mas não vê a tela.

## O que é enviado

- Um identificador aleatório do visitante, gerado no primeiro uso e guardado no Keychain só deste aparelho. Nunca o identificador de publicidade nem outro identificador do aparelho
- A decisão (ação e finalidades) e a versão do banner
- O aplicativo (Bundle ID), a versão do SDK, a versão do sistema e o modelo genérico do aparelho (como `iPhone15,2`)
- O endereço IP chega à Trusto pela conexão e é guardado só como hash por organização

## Desenvolvimento

```sh
swift build
swift test
```

Os testes rodam no Mac, com transporte, armazenamento e relógio substituídos.

## Pendências

- Licença: a definir antes da primeira publicação
- Publicação: só pela pipeline de lançamento, a partir da `main`, com revisão obrigatória e proteção de branch (débito #120 da Trusto)
