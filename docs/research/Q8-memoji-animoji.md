# Q8 — Animoji/Memoji num app watchOS: dá para usar e animar poses?

**Resposta curta: não.** Não existe API pública para instanciar, renderizar ou animar
Animoji/Memoji dentro de uma app de terceiros — menos ainda no watchOS. O que existe
é uma forma de **mostrar** Genmoji/Memoji **estáticos** como glifo dentro de texto
(`NSAdaptiveImageGlyph`, watchOS 11+), sem controlo sobre a imagem e sem animação.

A alternativa implementada foi um **personagem vetorial próprio com poses**
(`AssistantAvatar`), descrito no fim.

### Q1 — Existe API pública para Animoji/Memoji animados? `[A]`

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** Não. A superfície pública só expõe o *tipo de mensagem* (INMessageTypeAnimoji) e um modelo de imagem para glifos em texto; nada que instancie ou anime um avatar.
- **Evidência:** [S1] [S2] [S6] [S7]
- **Lacunas → sub-perguntas:** —

Não. A pesquisa na superfície pública da Apple só devolve:

| Superfície | O que é | Serve para o pedido? |
|---|---|---|
| `INMessageTypeAnimoji` ([`INMessage.h:42`][S6]) | um **enum** de tipo de mensagem nas Intents | não — descreve o tipo, não desenha nada |
| `NSAdaptiveImageGlyph` ([`NSAdaptiveImageGlyph.h`][S2]) | modelo de imagem multi-resolução para usar **Genmoji/Memoji como glifo em texto** | não para poses: é estático e a imagem vem do sistema |
| `MSSticker` (extensão de Mensagens) | sticker para a app Mensagens | não — não há forma de gerar um sticker de Memoji |
| Genmoji (WWDC24) `[S1]` | o utilizador cria; apps apenas **exibem** o glifo | não |
| Memoji/Animoji do sistema `[S7]` | nascem no teclado/Messages como stickers `[S7]` | não — sem acesso programático |

Citação literal da Apple, sessão WWDC24 `[S1]`:

> "Introducing NSAdaptiveImageGlyph, a brand new API to support using Genmoji and other
> personalized images just like a standard emoji! … Anywhere that can support rich text
> can support Genmoji and all of your expressive images."

Ou seja: a Apple expõe **exibição de imagens personalizadas em texto**, não renderização
de um avatar animado.

### Q2 — E o AvatarKit? `[A]`

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** AvatarKit é privado: inexistente nos SDKs de iOS/watchOS e presente só como PrivateFramework no macOS. Usá-lo viola a guideline 2.5.1.
- **Evidência:** [S4] [S5]
- **Lacunas → sub-perguntas:** —

`AvatarKit` é o framework que desenha Animoji/Memoji (classe `AVTAvatar`, presets `AVTPreset`).
Evidência local, que é o que decide:

- **watchOS 27 SDK**: não existe — nem em `Frameworks/`, nem em `PrivateFrameworks/` `[S4]`.
- **iOS 27.1 SDK**: não existe em nenhuma das duas pastas `[S4]`.
- **macOS 27 SDK**: existe **apenas** como `PrivateFrameworks/AvatarKit.framework` `[S5]`,
  isto é, sem headers públicos e sem link público.

Linkar um framework privado viola o **App Store Review Guideline 2.5.1** (só APIs
públicas), e num dispositivo real não existe contrato de estabilidade nenhum. Mesmo que
funcionasse numa build pessoal, quebra a cada atualização.

### Q3 — O caminho "conduzir um avatar 3D com a cara" existe? `[A]`

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** O caminho existe apenas em iOS: ARKit com ARFaceAnchor. O watchOS não tem ARKit nem RealityKit, e o Apple Watch SE não tem câmara.
- **Evidência:** [S3] [S4]
- **Lacunas → sub-perguntas:** —

Existe, mas **não no relógio**:

| Framework | iOS | watchOS |
|---|---|---|
| `ARKit` (com `ARFaceAnchor`, blend shapes) | sim `[S3]` | **não** |
| `RealityKit` | sim | **não** |
| `SceneKit` | sim | sim |
| `SpriteKit` | sim | sim |

Sem `ARKit` nem `RealityKit`, o watch não tem tracking facial nem renderizador 3D de
alto nível; e o Apple Watch SE nem tem câmara.

### Q4 — O que é possível fazer legalmente no watchOS? `[A]`

- **Estado:** respondida
- **Prioridade:** media
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** Mostrar Genmoji/Memoji estáticos como glifo em texto (NSAdaptiveImageGlyph, watchOS 11+) ou desenhar um personagem próprio. A primeira não permite poses.
- **Evidência:** [S2] [S1]
- **Lacunas → sub-perguntas:** —

1. **Mostrar** um Genmoji/Memoji que o utilizador tenha criado, como glifo em texto
   (`NSAdaptiveImageGlyph`, disponível em `watchos(11.0)` `[S2]`). É estático e o app
   não controla a imagem — não serve para "poses".
2. **Desenhar o nosso próprio personagem** com `Canvas`/`TimelineView` ou `SpriteKit`,
   com todas as poses que quisermos. É o que foi feito.

### Q5 — Qual a melhor alternativa animada e com poses? `[B]`

- **Estado:** respondida
- **Prioridade:** media
- **Confiança:** moderada
- **Origem:** brief (ronda 0)
- **Resposta:** Canvas + TimelineView com poses como dados; alternativa a SpriteKit/SceneKit, que trazem custo sem benefício num ecrã de 184 pt.
- **Evidência:** [S8] [S1]
- **Lacunas → sub-perguntas:** —

`Canvas` + `TimelineView(.animation)` dentro de SwiftUI (a base que a Apple documenta para watchOS `[S8]`): sem dependências, desenha a
30 Hz no relógio, e as poses são **dados** (um `struct AvatarPose` por estado) em vez de
arte importada. Comparado com SpriteKit (atlas de imagens, mais pesado numa app que já
não tem GPU a sobrar) e com SceneKit (3D sem necessidade num ecrã de 184 pt), é a opção
com melhor relação controlo/custo.

## Decisão

Implementado `AssistantAvatar` (`apps/watch/WatchPilot/UI/AssistantAvatar.swift`):
personagem próprio com olhos, boca, antenas e tronco, uma Pose por estado do assistente:

| Estado | Pose |
|---|---|
| idle | respira, pisca a cada ~4 s, olhos à frente |
| listening | antenas em pé, olhos muito abertos, boca abre com a potência do microfone |
| uploading | olhos a olhar para cima, ondas de sinal, boca pequena |
| waiting | olhos a varrer, cabeça inclinada, três pontos de "a pensar" |
| answering | olhos fechados em arco, sorriso, pequeno salto |
| failed | olhos semicerrados, boca para baixo, ombros caídos, paleta vermelha |

## Fontes

- [S1] Apple. *Bring expression to your app with Genmoji*, WWDC24. <https://developer.apple.com/videos/play/wwdc2024/10220> · oficial · nível A · lida: trechos (via Tavily `extract`).
- [S2] Apple. `NSAdaptiveImageGlyph` — `API_AVAILABLE(… watchos(11.0) …)`. Header lido em `WatchOS27.0.sdk/.../UIKit.framework/Headers/NSAdaptiveImageGlyph.h`. Documentação: <https://developer.apple.com/documentation/uikit/nsadaptiveimageglyph> · documentação · A.
- [S3] Apple. `ARFaceAnchor` — header lido em `iPhoneOS27.1.sdk/.../ARKit.framework/Headers/ARFaceAnchor.h`. Documentação: <https://developer.apple.com/documentation/arkit/arfaceanchor> · documentação · A.
- [S4] Ausência de `AvatarKit.framework` e de `ARKit`/`RealityKit` em `WatchOS27.0.sdk/System/Library/{Frameworks,PrivateFrameworks}` (listagem local). Índice público de frameworks: <https://developer.apple.com/documentation/technologies> · evidência direta · A.
- [S5] `MacOSX27.0.sdk/System/Library/PrivateFrameworks/AvatarKit.framework` (só `.tbd`, sem headers) — framework privado. Regra aplicável: App Store Review Guidelines 2.5.1 <https://developer.apple.com/app-store/review/guidelines/#software-requirements> · evidência direta · A.
- [S6] `Intents.framework/Headers/INMessage.h:42` — `INMessageTypeAnimoji`. Documentação: <https://developer.apple.com/documentation/intents/inmessagetype> · documentação · A.
- [S7] Apple Support. *Use Memoji on your iPhone or iPad Pro*. <https://support.apple.com/en-us/111115> · oficial · B (contexto: Memoji vive no teclado/Messages).
- [S8] Apple Developer. *watchOS*. <https://developer.apple.com/watchos> · oficial · B.

## Limitações desta pesquisa

- Não houve confirmação documental explícita do tipo "Memoji não está disponível para
  apps de terceiros" numa página de Apple: essa conclusão vem da **ausência do símbolo
  nos SDKs** (evidência directa e mais forte) e do texto do WWDC24 sobre o que as apps
  podem fazer com imagens personalizadas.
- O pool Tavily estava sem chaves válidas; as pesquisas correram em modo *keyless*
  (limites severos), e a maior parte da evidência é local (SDKs) por ser mais fiável.
- Não foi testado `NSAdaptiveImageGlyph` em hardware (só a disponibilidade declarada
  no SDK).
