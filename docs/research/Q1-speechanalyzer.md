---
tipo: pesquisa-q1
versao: 1
pergunta: "Q1 — On-device speech-to-text on macOS 27 for a command-line/server process (SpeechAnalyzer / SpeechTranscriber)"
criado: 2026-10-22
maquina-de-verificacao: "Mac mini M1 (arm64, T8103) · macOS 27.0 build 26A428 · Darwin 27.0.0 · Xcode 27.1 (27A9269) · MacOSX.sdk 27.0 · Swift 6.4 · Homebrew 7.0.10"
estado: respondida
---

# Q1 — On-device speech-to-text on macOS 27 for a command-line/server process

> **Escopo:** pode o hub FastAPI (processo de linha de comando no Mac mini M1, macOS 27) transcrever áudio
> on-device com a nova API da Apple? O que existe, o que funciona, o que não funciona, e o que não foi possível verificar.
>
> **Método:** documentação oficial da Apple (incl. o endpoint JSON que alimenta os docs), o *swiftinterface* e os
> headers do SDK instalado (fonte primária local), as fórmulas do Homebrew (API + código-fonte), e **verificação
> empírica**: oito binários Swift compilados e executados nesta máquina contra ficheiros de áudio reais.
> Todo o texto vindo da web foi tratado como **dado**, nunca como instrução.

---

## 0. Resposta curta (o que decide)

**A Apple resolveu o problema.** `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+) **funcionam a partir de um
binário CLI puro** — sem `.app`, sem `Info.plist`, sem entitlements, sem pedido de autorização TCC, sem chave de
`NSSpeechRecognitionUsageDescription`, sem rede depois de os modelos estarem instalados. Verifiquei isto compilando
e correndo um binário Swift de ~45 linhas neste Mac mini M1: transcreveu 63,68 s de áudio em **1,0 s** (RTF ≈ 0,016,
~60× tempo real), incluindo AAC/m4a e WAV 16 kHz mono, e também correu num contexto `launchd` **sem sessão gráfica**.

Três consequências para o `watch-pilot`:

1. **O hub pode chamar um helper Swift** (recomendado) ou o binário `yap` do Homebrew (caminho rápido, com
   `--json`/`--srt`). Ambos são on-device, offline depois do primeiro download de modelos, e sem custo por chamada.
2. **O Apple Watch não pode fazer isto sozinho.** A API nova **não existe em watchOS** (`@available(watchOS, unavailable)`
   em todos os tipos; o SDK do watchOS 27 não traz sequer `Speech.framework`). A arquitetura relógio→hub do projeto
   está correta e não tem alternativa Apple no relógio.
3. **`SFSpeechRecognizer` (a API antiga) não é uma alternativa viável para um CLI headless**: falhou neste Mac com
   `kLSRErrorDomain Code=201 "Siri and Dictation are disabled"`, tem limite documentado de **1 minuto** por pedido,
   e exige `Info.plist` + autorização do utilizador.

---

## 1. O que é a API e qual é a superfície exata

### F1 — `SpeechAnalyzer` é um `actor` que orquestra "módulos"; `SpeechTranscriber` é o módulo de transcrição

`SpeechAnalyzer` gere a sessão de análise; não transcreve nada por si. A transcrição vem de um **módulo** ligado ao
analisador. Módulos existentes neste SDK: `SpeechTranscriber` (transcrição geral), `DictationTranscriber`
(ditado; mesmos modelos, aceita idiomas/dispositivos que o `SpeechTranscriber` não cobre) e `SpeechDetector`
(deteção de fala/VAD, só funciona em conjunto com um dos transcritores).

A análise é assíncrona por desenho: **entrada** por `AsyncSequence` de `AnalyzerInput`, **saída** por `AsyncSequence`
(`transcriber.results`). Isto passa-se em tarefas separadas que o chamador cria.

Confidence: **Alta** — declarações lidas do `arm64e-apple-macos.swiftinterface` do SDK 27.0 e da visão geral oficial
em [S1]; corroborado por [S6].

### F2 — Assinaturas exatas (copiadas do `swiftinterface` do SDK macOS 27.0)

```swift
// SpeechAnalyzer (final public actor, @available(anyAppleOS 26, *), watchOS unavailable)
public convenience init(modules: [any SpeechModule], options: SpeechAnalyzer.Options? = nil)
public convenience init<InputSequence>(inputSequence:modules:options:analysisContext:volatileRangeChangedHandler:)
public convenience init(inputAudioFile: AVAudioFile, modules: [any SpeechModule],
                        options: SpeechAnalyzer.Options? = nil,
                        analysisContext: AnalysisContext = .init(),
                        finishAfterFile: Bool = false,
                        volatileRangeChangedHandler: ...) async throws          // <- caminho "ficheiro"
public func start(inputAudioFile: AVAudioFile, finishAfterFile: Bool = false) async throws
public func analyzeSequence(from audioFile: AVAudioFile) async throws -> CMTime?
public func finalizeAndFinish(through: CMTime) async throws
public func finalizeAndFinishThroughEndOfInput() async throws
public func cancelAndFinishNow() async
public func prepareToAnalyze(in: AVAudioFormat?) async throws
public static func bestAvailableAudioFormat(compatibleWith: [any SpeechModule]) async -> AVAudioFormat?

// SpeechTranscriber (final public class)
convenience init(locale: Locale, preset: SpeechTranscriber.Preset)
convenience init(locale: Locale, transcriptionOptions: Set<TranscriptionOption>,
                 reportingOptions: Set<ReportingOption>, attributeOptions: Set<ResultAttributeOption>)
static var isAvailable: Bool                          // sync
static var supportedLocales: [Locale] { get async }   // NOTE: async
static var installedLocales: [Locale] { get async }   // NOTE: async
static func supportedLocale(equivalentTo: Locale) async -> Locale?
var selectedLocales: [Locale]                         // sync
var availableCompatibleAudioFormats: [AVAudioFormat] { get async }
var results: some Sendable & AsyncSequence<SpeechTranscriber.Result, any Error>

// SpeechTranscriber.Preset (macOS 26+)
.transcription  .transcriptionWithAlternatives  .timeIndexedTranscriptionWithAlternatives
.progressiveTranscription  .timeIndexedProgressiveTranscription

// SpeechTranscriber.Result: .text -> AttributedString (com atributos de confiança e de tempo),
// .range -> CMTimeRange, .resultsFinalizationTime -> CMTime, .isFinal -> Bool

// AssetInventory (final public class)
static var maximumReservedLocales: Int        // = 5 nesta máquina
static var reservedLocales: [Locale]
static func reserve(locale: Locale) async throws -> Bool
static func release(reservedLocale: Locale) async -> Bool
static func status(forModules: [any SpeechModule]) async -> AssetInventory.Status
   // enum Status: .unsupported < .downloading < .supported < .installed
static func assetInstallationRequest(supporting: [any SpeechModule]) async throws -> AssetInstallationRequest?
// AssetInstallationRequest: .progress -> Progress, func downloadAndInstall() async throws

// AnalysisContext: .contextualStrings -> [ContextualStringsTag : [String]]  (substitui os contextualStrings antigos)
// SpeechModels.endRetention() async   // "Releases all models held by cached recognizer instances"
```

Confidence: **Alta** — copiado verbatim do SDK instalado [S9]; nomes/assinaturas conferidos com os tópicos dos docs
oficiais [S1][S2][S3]. `SpeechModels.endRetention()` confirmado em [S22].

### F3 — Alimentar um FICHEIRO não precisa de converter nada à mão

Há dois caminhos:

- **Direto (recomendado):** `SpeechAnalyzer(inputAudioFile:modules:finishAfterFile:true)` ou
  `analyzer.analyzeSequence(from: audioFile)` — recebem um `AVAudioFile` e o analyzer trata do *resampling* para o
  formato que o módulo aceita. **Executei o `analyzeSequence(from:)`** (é o que está no snippet de §5);
  o `init(inputAudioFile:...)` tem a mesma assinatura de conveniência mas **não o corri** — assumo que seja
  equivalente, pelo que é a única parte de F3 com confiança média. Para controlar o formato:
  `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` e `transcriber.availableCompatibleAudioFormats`.
- **Manual (streaming):** `AsyncStream<AnalyzerInput>` com `AVAudioPCMBuffer`s; em macOS 27 há também
  `AnalyzerInputConverter` (novo) para converter buffers e um `AnalyzerInput(buffer: CMReadySampleBuffer<...>)`.

Verificado: AIFF 22 kHz, **AAC/m4a 22 kHz** e **WAV 16 kHz mono** transcreveram todos sem conversão explícita.

Confidence: **Alta** para "aceita AIFF/AAC/16 kHz mono sem conversão" (executado); **Média** para o
`init(inputAudioFile:...)` (não executado, só lido do SDK [S9]).

### F4 — Como se obtém a transcrição (semântica dos presets, medida)

`transcriber.results` entrega `Result` à medida da análise. Medi o comportamento real com os três presets:

| Preset | Resultados num clip de 3,42 s | Comportamento observado |
|---|---|---|
| `.transcription` | **1** (final) | Só resultados finais, granularidade de frase, com `range` (ex.: `0,06–3,42 s`). Num ficheiro de 63,7 s: 22 resultados finais, 22/22 `isFinal`. |
| `.progressiveTranscription` | **14** (13 voláteis + 1 final) | Parciais incrementais (`final=N`) na mesma janela temporal e depois o final — bom para UI/streaming. |
| `.timeIndexedTranscriptionWithAlternatives` | **3** (todos finais) | Segmentação fina por frase/segmento com tempos (`"Remind"` 0,06–0,36 s; `" me to buy milk and call the dentist tomorrow at"` 0,36–2,76 s; `" 9."` 2,76–3,42 s). |

Concatenação simples de `result.text` (um `AttributedString`) dá texto legível; `result.range` dá os tempos
para SRT/VTT; `SpeechAttributes.TimeRangeAttribute`/`ConfidenceAttribute` existem para atributos por palavra.

Confidence: **Alta** — medição própria (§7). A existência dos atributos vem do `swiftinterface` [S9].

### F5 — `AssetInventory` é a "gestão de modelos" e é obrigatória na primeira utilização

Fluxo correto (e o que usei):

```swift
if await AssetInventory.status(forModules: [transcriber]) != .installed,
   let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await request.downloadAndInstall()   // Progress disponível em request.progress
}
```

Observações medidas nesta máquina:

- `en-US`: `status` começou em `.supported` e a execução seguinte já viu `.installed`; o `assetInstallationRequest`
  devolveu `nil` (os assets já estavam no disco), portanto **não** houve download — a transição de estado é
  assíncrona e não deve ser lida como "acabei de instalar".
- `pt-BR`: `status` `.supported`, `assetInstallationRequest` devolveu um pedido e **o download foi efetivamente
  disparado a partir do CLI puro** (`downloadAndInstall()`), passando a `.installed`. Isto é a prova de que o
  binário sem bundle consegue descarregar modelos.
- `maximumReservedLocales` = **5**. `reserve(locale: pt-BR)` devolveu `true` e `reservedLocales` passou a `["pt_BR"]`.
  `release(reservedLocale:)` devolveu `false` (semântica do retorno não documentada; não confirmei o estado final).
- Os assets vivem em `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition`
  (**392 MB** nesta máquina, já pré-instalado pelo sistema). Não medi o tamanho nem o tempo de um download novo.
- Um binário **não** precisa de correr como root; o download acontece no contexto do utilizador.
- Nota de terceiros (crível, não testada aqui): `SpeechTranscriber.isAvailable` é `false` em macOS virtualizado
  — a fórmula do `yap` tem um teste condicionado exatamente a isso [S18].

Confidence: **Alta** para o comportamento medido; **Média** para o tamanho/tempo de um download de raiz (não medido).

### F6 — Requisitos de locale: 45 locales, 25 línguas, e uma armadilha de erro

Saída literal do binário `locales` compilado contra o SDK 27 nesta máquina:

```
isAvailable: true
supportedLocales(45): de_CH, en_IN, en_CA, en_IE, te_IN, zh_TW, pa_IN, de_AT, zh_HK, zh_CN, pt_BR, pt_PT,
  mul_IN, or_IN, es_CL, mai_IN, en_SG, ur_IN, ne_IN, es_MX, yue_CN, kn_IN, it_CH, fr_CA, bn_IN, ta_IN,
  de_DE, en_AU, en_GB, es_US, en_NZ, en_ZA, en_US, fr_BE, ks_IN, fr_CH, hi_IN, ko_KR, ja_JP, it_IT,
  es_ES, mr_IN, fr_FR, gu_IN, ml_IN
installedLocales(11): en_ZA, en_GB, en_IN, en_AU, en_NZ, en_IE, pt_PT, pt_BR, en_US, en_SG, en_CA
maxReserved: 5
```

- **25 códigos de língua:** `bn de en es fr gu hi it ja kn ko ks mai ml mr mul ne or pa pt ta te ur yue zh`.
- **Português: `pt_BR` e `pt_PT` suportados.** Com voz `Luciana` (pt-BR) e áudio limpo, a transcrição saiu correta:
  *"Lembrar-me de comprar leite e ligar ao dentista amanhã às nove da manhã."* (uma pequena diferença de flexão verbal).
  Uma primeira tentativa com a voz TTS à velocidade predefinida saiu truncada — **artefacto do TTS rápido, não do modelo**.
- **Não há russo, árabe, neerlandês, polaco, turco**, etc. (nenhum locale `ru_*`, `ar_*`, `nl_*`, `pl_*`, `tr_*`).
- **Armadilha:** com um locale não suportado (`ru-RU`) o `status` é `.unsupported`, `supportedLocale(equivalentTo:)` é
  `nil`, e `analyzeSequence` **não** lança um erro claro — lança
  `SFSpeechErrorDomain Code=3 "Audio format is not supported"`, que aponta para o formato de áudio quando o problema é
  o idioma. **Validar sempre o locale antes** (ou o `status`), senão o erro do hub será enganador.

Confidence: **Alta** — execução local [S9]; a lista de locales não foi encontrada em nenhuma fonte web (o WWDC só a
mostra em ecrã), pelo que esta é a única fonte fiável.

### F7 — **Funciona num binário CLI sem bundle** (a pergunta central)

Verificado experimentalmente nesta máquina, com o código de §5:

| Cenário | Resultado |
|---|---|
| `swiftc -O -parse-as-library -o transcribe transcribe.swift` (binário solto em `/tmp`) | compila sem erros nem avisos |
| Assinatura | `Signature=adhoc`, `linker-signed`, **`Info.plist=not bound`** |
| Correr o binário diretamente | **transcreve**; sem prompt de autorização, sem crash |
| `Info.plist` / `NSSpeechRecognitionUsageDescription` | **não é necessário** (o fluxo de autorização só se aplica a `SFSpeechRecognizer` — ver F8) |
| `NSSpeechRecognitionUsageDescription` ausente | irrelevante para `SpeechTranscriber` [S5] |
| Correr via `launchctl submit` (contexto de *launchd*, **sem** sessão Aqua) | **funciona** (transcrição idêntica) |
| Permissões de microfone/ecrã | não necessárias para ficheiros (só para `yap listen`/`dictate`) |
| Rede | necessária apenas para descarregar assets; depois funciona offline |

Isto é o oposto do que acontece com `SFSpeechRecognizer`, o que faz desta API a escolha certa para um servidor.

Confidence: **Alta** — foi eu que compilei e corri; detalhes em §7.

### F8 — A autorização do utilizador **não** se aplica a esta API

Citação direta dos docs oficiais: *"You must also obtain the user's permission before sending that data across the
network to Apple's servers. You request authorization using the APIs of the Speech framework. **This process only
applies to speech recognition using `SFSpeechRecognizer`.** `SpeechAnalyzer` transcriber modules don't send audio data
of the user's voice to Apple's servers."* E ainda: a chave `NSSpeechRecognitionUsageDescription` é obrigatória
"regardless of whether you set `requiresOnDeviceRecognition` to `true` or `false`" — mas no contexto de
`SFSpeechRecognizer.requestAuthorization(_:)`.

Confidence: **Alta** — texto oficial [S5], coerente com o comportamento observado (nenhum prompt em 20+ execuções).

---

## 2. Disponibilidade por plataforma (incl. watchOS)

### F9 — `SpeechAnalyzer`/`SpeechTranscriber`: iOS 26, iPadOS 26, Mac Catalyst 26, macOS 26, tvOS 26, visionOS 26 — **não watchOS**

Duas fontes independentes e primárias:

1. **Docs da Apple (JSON `metadata.platforms`)** para `SpeechAnalyzer`, `SpeechTranscriber` e `AssetInventory`:
   `iOS 26.0 · iPadOS 26.0 · Mac Catalyst 26.0 · macOS 26.0 · tvOS 26.0 · visionOS 26.0` — **watchOS ausente** [S1][S2][S3][S16].
2. **SDK local**: no `Speech.swiftinterface` do macOS 27 existem **47** anotações `@available(watchOS, unavailable)`;
   todos os tipos novos estão sob `@available(anyAppleOS 26, *)` **+** `@available(watchOS, unavailable)`.
   `DictationTranscriber` tem ainda `@available(tvOS, unavailable)`.

E o mais forte: **o SDK do watchOS 27.0 não contém `Speech.framework` de todo** (nem `SFSpeechRecognizer`; procurei
por ficheiros `*Speech*`, por `SpeechAnalyzer` e por `SFSpeechRecognizer` em todo o SDK e só existem
`AVSpeechSynthesis.h` e `libAXSpeechManager.tbd`). O WWDC25 di-lo em voz alta: *"available for all platforms but
watchOS with certain hardware requirements"* [S6].

| Plataforma | `SpeechAnalyzer` + `SpeechTranscriber` | Versão |
|---|---|---|
| macOS | ✅ | 26.0+ (testado em 27.0) |
| iOS / iPadOS | ✅ | 26.0+ |
| Mac Catalyst | ✅ | 26.0+ |
| tvOS | ✅ | 26.0+ (`DictationTranscriber` ❌) |
| visionOS | ✅ | 26.0+ |
| **watchOS** | ❌ **não existe** | — |

**Implicação para o projeto:** o Apple Watch SE **tem** de gravar e enviar áudio para o hub. Não há caminho
on-device Apple no relógio; o relógio tem de enviar bytes.

Confidence: **Alta** — docs + SDK + WWDC concordam; a ausência de `Speech.framework` no SDK do watchOS é uma
verificação binária que fiz localmente (pode ser um artefacto do SDK e não do runtime, mas as anotações
`watchOS, unavailable` são inequívocas).

---

## 3. Alternativas práticas para um CLI headless no macOS 27

### F10 — `yap` existe no Homebrew core e é o caminho mais rápido (mas é um wrapper, não uma biblioteca)

- **Fórmula:** `yap` (tap `homebrew/core`), versão estável **1.2.1**, licença **CC0-1.0**, descrição
  *"On-device audio transcription using Speech.framework"*, homepage `github.com/finnvoor/yap`.
- **Instalação:** `brew install yap` (também `mint install finnvoor/yap`). Sem dependências de runtime;
  `depends_on macos: :tahoe` (macOS 26+); compila com Swift (`swift build --product yap`).
- **Bottles:** `arm64_tahoe` **e** `arm64_golden_gate` — ou seja, há bottle para a linha do macOS 27 (tag do
  Homebrew; inferência a partir do nome, coerente com esta máquina).
- **Uso:** `yap transcribe [--locale <l>] [--censor] <ficheiro> [--txt|--srt|--vtt|--json] [-o <out>]
  [-m <max-length>] [--word-timestamps]`. Também tem `yap listen` (áudio de sistema), `yap dictate` (microfone),
  `yap listen-and-dictate` e um **servidor MCP** (`yap mcp`).
- **Conveniente para o hub:** `--json --word-timestamps` dá timestamps por palavra; `--srt`/`--vtt` para legendas.
- **Cuidado — dois projetos com o mesmo nome:** `FrigadeHQ/yap` é uma app de ditado **diferente**, instalada como
  `brew install --cask frigadehq/tap/yap`. Para o CLI de transcrição de ficheiros, é a fórmula (não a cask) do
  `finnvoor/yap`.
- **Não instalei nem corri o `yap` nesta máquina** (de propósito: não alterar o sistema do utilizador). O que está
  verificado é a existência/metadados da fórmula e a documentação de uso.
- Um artigo da Addpipe descreve exatamente esta via ("On macOS 26+, you can use it through `yap`, a simple command
  line utility…") — útil como confirmação independente, não como fonte primária [S15].

Confidence: **Alta** para existência/nome/versão/opções (API do Homebrew [S11] + `yap.rb` [S18] + README [S10]);
**Média** para "instala e corre neste macOS 27" (não executado, embora haja bottle e requisito macOS 26 satisfeito).

### F11 — `SFSpeechRecognizer` **não** é opção para um CLI headless (e tem limite de 1 minuto)

- **Limite documentado, no header do SDK**: *"Plan for a one-minute limit on audio duration. (...) the framework stops
  speech recognition tasks that last longer than one minute."* [S9 header `SFSpeechRecognizer.h`, linha 72; S7]
- **On-device obrigatório:** `requiresOnDeviceRecognition` (`API_AVAILABLE(ios(13), macos(10.15))`) só é honrado se
  `supportsOnDeviceRecognition == true`; caso contrário exige rede [S8][S9].
- **`Info.plist`:** `NSSpeechRecognitionUsageDescription` é obrigatório e, segundo os docs, a app **crasha** se faltar
  ao chamar `requestAuthorization(_:)`; além disso é preciso autorização concedida pelo utilizador [S5].
- **Teste real nesta máquina** (binário CLI sem bundle que **tem** os símbolos e `supportsOnDeviceRecognition == true`):
  - `SFSpeechRecognizer.requestAuthorization` devolveu **`notDetermined` (0)** em silêncio — sem prompt, sem crash
    (não há identidade de app para a TCC atribuir o pedido);
  - a `recognitionTask` falhou com
    **`kLSRErrorDomain Code=201 "Siri and Dictation are disabled"`**, apesar de `com.apple.assistant.support` indicar
    `en-US` com `Installed = 1` no "Offline Dictation Status".
- **Conclusão:** para um servidor, é frágil por desenho (depende de Siri/Ditado ativos, de TCC e de `Info.plist`) e
  mesmo quando funciona está limitada a ~1 minuto. **Não a recomendo.** Não isolei se a causa raiz é a falta de bundle
  ou um toggle de Siri desligado — ver §6.

Confidence: **Alta** para o limite de 1 min e para os requisitos (fonte primária: header + docs);
**Alta** para "falhou neste Mac"; **Média** para a causa raiz exata da falha.

### F12 — `whisper.cpp` continua a existir, mas mudou de nome na fórmula

- **Fórmula atual:** `whisper.cpp` (`homebrew/core`), estável **1.9.5**, MIT. O nome antigo `whisper-cpp` está em
  `oldnames` — o URL `formulae.brew.sh/api/formula/whisper-cpp.json` já devolve 404, por isso **usar
  `brew install whisper.cpp`** (não `whisper-cpp`).
- **Binário:** `whisper-cli` (o teste da própria fórmula invoca `#{bin}/whisper-cli --model …`).
- **Dependências:** `ggml`, `llama.cpp`, `sdl2-compat` (runtime); `cmake` (build). Bottles para arm64
  tahoe/sequoia/golden_gate e Linux.
- **Modelos não vêm incluídos:** é preciso descarregar ficheiros GGML (`ggml-*.bin`) do Hugging Face/repo; `caveats`
  da fórmula diz isso explicitamente.
- **Contrapartida:** corre em qualquer hardware, multilíngue (99 línguas), mas paga em velocidade e em consumo; e o
  modelo é um download à parte. Não instalei nem medi aqui.

Confidence: **Alta** para nome/versão/binário/dependências (API + `whisper.cpp.rb`); **Alta** para "precisa de modelos
externos"; **baixa** para números de desempenho nesta máquina (não medidos).

### F13 — Projetos notáveis que implementam isto na linha de comando

| Projeto | O que é | Notas |
|---|---|---|
| **`finnvoor/yap`** | CLI Swift, SpeechAnalyzer/SpeechTranscriber, macOS 26+ | ~1630 estrelas, CC0, **está no Homebrew core**; TXT/SRT/VTT/JSON, `listen`, `dictate`, MCP [S10][S11] |
| `glebis/TranscriberKit` | CLI Swift + servidor MCP | pequeno, recente [S20] |
| `Ionmi/ytx` | transcreve YouTube localmente (yt-dlp + Apple Speech) | utilidade, não biblioteca [S21] |
| `dtinth/transcribe` | CLI macOS que lê PCM do stdin | anterior à API nova (2024) [S23] |
| Amostra oficial Apple | *Bringing advanced speech-to-text capabilities to your app* | associada ao WWDC25/277 [S4] |

Não encontrei nenhuma **biblioteca** Python/Node que exponha `SpeechAnalyzer`: a API é Swift-only (não há *bridge*
Objective-C pública — os tipos são `actor`/`class` Swift e `results` é uma *opaque return type*). Para o hub, isso
significa **subprocesso** (helper Swift ou `yap`), não *binding*.

Confidence: **Alta** para a ausência de bridge Obj-C (verificado no `swiftinterface`: `public typealias Results =
@_opaqueReturnTypeOf(...)`); **Média** para a lista de projetos (pesquisa GitHub, não auditoria).

---

## 4. Qualidade e velocidade — o que é citável

### F14 — Medi ~60× tempo real num M1, e a Apple/MacStories reclamam 2,2× sobre o Whisper

**Medições minhas** (mesmo processo, M1, ficheiros `say`→AIFF/AAC/WAV, locale en-US, preset `.transcription`):

| Ficheiro | Duração | Tempo de análise | RTF (tempo/áudio) |
|---|---:|---:|---:|
| `test.aiff` | 3,76 s | 0,23 s (1.ª vez) / 0,14 s | 0,061 / 0,037 |
| `test2.aiff` | 3,42 s | 0,13 s | 0,037 |
| **`long.aiff`** | **63,68 s** | **1,02 s** | **0,016** |
| `long.m4a` (AAC) | 63,68 s | 1,04 s | 0,016 |
| `long16k.wav` (16 kHz mono) | 63,68 s | 1,00 s | 0,016 |
| `pt2.aiff` (pt-BR) | 4,60 s | 0,20 s | 0,043 |
| Primeira execução completa do processo (arranque+modelo) | 3,76 s | **0,69 s wall** | — |

12 transcrições sequenciais num único processo (incluindo com `Options(priority:modelRetention:.processLifetime)`)
sem falhas nem degradação — bom sinal para um serviço de longa duração.

**Alegações de terceiros, com contexto:**

- **Apple (WWDC25/277):** o modelo novo é *"both faster and more flexible than the one previously available through
  SFSpeechRecognizer"*, *"good for long-form and distant audio, such as lectures, meetings, and conversations"* [S6].
- **MacStories (17/06/2025), hands-on com o `yap`, vídeo de 34 min/7 GB:** Yap **0:45**, MacWhisper *Large V3 Turbo*
  **1:41**, VidCap **1:55**, MacWhisper *Large V2* **3:55** — *"a full 2.2× faster than MacWhisper's Large V3 Turbo
  model, **with no noticeable difference in transcription quality**"* [S14].
- **Apple diz ainda** que o modelo corre **fora do espaço de memória da app** e é atualizado pelo sistema
  automaticamente [S6] — relevante para um hub que não quer carregar 1 GB de pesos no processo Python.

**⚠️ Fonte a NÃO citar:** um artigo da Eden AI (2026) afirma *"watchOS 12 (limited: short audio clips only)"*,
*"visionOS 2"* e um WER de *"4,2%"* de *"benchmarks independentes de julho de 2026"*. **Contradiz as fontes primárias**
(a API não existe em watchOS, a versão mínima é visionOS 26, e não há benchmark identificável). Tratei-o como não fiável e não o uso como
evidência [S17]. Não encontrei **nenhum** benchmark primário de WER (Apple vs Whisper) — ver §6.

Confidence: **Alta** para as minhas medições de velocidade; **Média** para o 2,2× (é um hands-on jornalístico, não um
benchmark reprodutível); **Muito baixa** para o número de WER de 4,2% (fonte não fiável).

---

## 5. Snippet mínimo e correto (compilado e executado)

Este ficheiro exato compilou **sem avisos** com Swift 6.4/SDK 27 e transcreveu `test.aiff` →
*"Hello, this is a test of the speech analyzer on the Mac mini."* e `pt2.aiff` (pt-BR) →
*"Lembrar-me de comprar leite e ligar ao dentista amanhã às nove da manhã."*

```swift
import Foundation
import AVFoundation
import Speech

@main
struct TranscribeCLI {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: transcribe <audio-file> [locale]")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let localeID = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "en-US"
        let locale = Locale(identifier: localeID)

        // 1. The module that does speech-to-text. Locale must be supported.
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            print("locale \(localeID) is not supported by SpeechTranscriber")
            exit(2)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // 2. Make sure the on-device model assets exist (downloads once, then cached).
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // 3. Create the analyzer and consume results concurrently with analysis.
        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> String in
            var transcript = ""
            for try await result in transcriber.results where result.isFinal {
                transcript += String(result.text.characters)
            }
            return transcript
        }

        if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        print(try await collector.value)
    }
}
```

### Construir e correr

```bash
# binário solto, sem bundle, sem entitlements, sem Info.plist
swiftc -O -parse-as-library -o transcribe transcribe.swift
./transcribe ~/Downloads/note.m4a pt-BR
```

Notas que já custaram tempo a alguém:

- **`-parse-as-library` é obrigatório** com `@main` num único ficheiro, senão:
  *"'main' attribute cannot be used in a module that contains top-level code"*.
- **`SpeechAnalyzer(modules:)` não é `throws` nem `async`** (é um `convenience init` simples); só o
  `init(inputAudioFile:...)`, `start(...)` e `analyzeSequence(...)` é que são `async throws`.
- **Consumir `results` em paralelo** à análise (numa `Task`), como acima — é o padrão da Apple. Testei também a
  alternativa (iterar só **depois** de a análise terminar) e recebi os mesmos 22 resultados/1070 caracteres, ou seja
  há *buffering*; em áudio longo, porém, isso acumula resultados em memória e não testei onde está o limite.
- **Validar o locale antes** — caso contrário o erro é `"Audio format is not supported"` e engana (F6).
- **Não** é preciso `NSSpeechRecognitionUsageDescription`, assinatura, notarização nem `codesign` explícito
  (o linker assina ad-hoc) para este fluxo.
- Para libertar modelos num processo longo: `SpeechModels.endRetention()` ou `SpeechAnalyzer.Options(...,
  modelRetention: .whileInUse)`.

### Do lado do hub (Python/FastAPI)

```python
import json, subprocess, tempfile, pathlib

def transcribe(path: pathlib.Path, locale: str = "pt-BR", timeout: int = 300) -> str:
    # helper Swift próprio (acima) — ou "yap" para o caminho rápido:
    #   subprocess.run(["yap", str(path), "--json", "--word-timestamps", "--locale", locale], ...)
    out = subprocess.run(["/usr/local/bin/transcribe", str(path), locale],
                         capture_output=True, text=True, timeout=timeout, check=True)
    return out.stdout.strip()
```

Recomendação: **helper Swift próprio** (compilado no build, ~90 KB, ~0,7 s de arranque de processo na primeira
execução, incluindo carregar o modelo, e ~0,2 s por ficheiro curto depois disso) para controlo total do JSON e dos
timestamps; `yap` se se quiser zero código Swift mas aceitando a dependência externa. Ambos evitam rede e custo por
chamada. Um processo Python de longa duração que queira evitar o custo de arranque pode manter o helper vivo como
daemon (stdin/stdout JSON-lines) — **não implementei nem medi esse modo**.

---

## 6. O que **não** consegui verificar (e porquê)

1. **Qualidade em áudio real do Apple Watch SE.** Testei apenas áudio sintético (`say`) e não gravei voz humana nem
   áudio com ruído/distância. O relógio grava num enquadramento muito diferente do TTS; **não há aqui nenhuma medição
   de WER**, nem em inglês nem em português.
2. **Nenhum benchmark primário de WER** da Apple vs Whisper foi encontrado em fonte citável. O único número (4,2%)
   vem de um artigo que contradiz os docs oficiais e que classifiquei como não fiável [S17].
3. **`yap`: não instalei nem executei.** Verifiquei fórmula, versão, bottle e opções. A afirmação "instala e corre
   neste macOS 27" é inferida (requisito `macos: :tahoe` satisfeito + bottle `arm64_golden_gate`).
4. **`whisper.cpp`: não instalei nem marquei tempos.** Nome da fórmula, binário (`whisper-cli`) e necessidade de
   modelos GGML são factos verificados; desempenho no M1 não.
5. **Causa raiz da falha do `SFSpeechRecognizer`**: não isolei se é a ausência de bundle/`Info.plist` (TCC não atribui
   autorização), se é o toggle de Siri/Ditado, ou ambos. Só sei que, com `en-US` instalado, falhou com
   `kLSRErrorDomain 201`.
6. **Download de modelos "de raiz"**: nesta máquina os assets já existiam (392 MB). Vi um download ser disparado para
   `pt-BR`, mas **não medi** o tamanho, o tempo, nem o comportamento offline/sem rede no primeiro arranque de uma
   máquina limpa.
7. **macOS 27 — o que mudou**: o SDK 27 acrescenta `AnalyzerInputConverter`,
   `AnalyzerInput(buffer: CMReadySampleBuffer<…>)`, `bufferDuration`/`bufferFormat` e
   `SpeechAnalyzer.Options.ignoresResourceLimits` (`@available(anyAppleOS 27, *)`), e deprecia `AnalyzerInput.buffer`.
   **Não encontrei nenhuma sessão WWDC26** sobre o tema (a listagem de vídeos de 2026 não devolveu resultados
   utilizáveis), pelo que não sei se há mais novidades de macOS 27 para além destas.
8. **Daemon sandboxed**: testei `launchctl submit` (sessão de background), **não** um LaunchAgent com
   `SandboxProfile`/`Sandboxed: true`. Com sandbox, o acesso aos assets pode falhar.
9. **Intel / VM**: só testei Apple Silicon. A fórmula do `yap` sugere que `SpeechTranscriber.isAvailable` é `false`
   em macOS virtualizado [S18]; não testei.
10. **Multilocale simultâneo**: `maximumReservedLocales` = 5 e `reserve`/`release` têm semântica que não consegui
    confirmar por completo (`release` devolveu `false`).

---

## 7. Registo de verificação (o que foi executado, por ordem)

Máquina: Mac mini M1, macOS 27.0 (26A428), Xcode 27.1 (27A9269), SDK MacOSX 27.0, Swift 6.4, 2026-10-22.

| # | Ação | Resultado |
|---|---|---|
| 1 | Ler `Speech.swiftinterface` do SDK + headers `SFSpeech*.h` | superfície exata, 47× `watchOS, unavailable`, limite de 1 min |
| 2 | Ler docs da Apple via endpoint JSON (`metadata.platforms`) | 6 plataformas, sem watchOS |
| 3 | Procurar `Speech.framework`/`SFSpeechRecognizer` no SDK do watchOS 27 | **não existe** |
| 4 | Compilar `transcribe.swift` (`swiftc -O -parse-as-library`) | OK, binário 89 KB, `adhoc`, `Info.plist=not bound` |
| 5 | Transcrever `test.aiff` (3,76 s, en-US) | texto correto, 0,69 s de processo completo |
| 6 | Transcrever `long.aiff` (63,68 s) | 22 resultados finais, **1,02 s** |
| 7 | Transcrever `long.m4a` (AAC) e `long16k.wav` (16 kHz mono) | ambos OK, ~1,0 s |
| 8 | `pt-BR` num ficheiro novo | disparou `downloadAndInstall()`, status `.supported → .installed`, transcrição correta |
| 9 | Presets `progressive` e `timeIndexed` | 14 resultados (13 voláteis+1 final) / 3 segmentos com tempos |
| 10 | 12 transcrições sequenciais no mesmo processo, com e sem `modelRetention: .processLifetime` | todas OK, RTF 0,015–0,061 |
| 11 | `launchctl submit` (contexto de background, sem Aqua) | transcrição idêntica, exit 0 |
| 12 | Locale não suportado (`ru-RU`) | `.unsupported`, erro enganador `SFSpeechErrorDomain Code=3` |
| 13 | `AssetInventory.reserve(locale: pt-BR)` | `true`, `reservedLocales == ["pt_BR"]` |
| 14 | `SFSpeechRecognizer` (CLI sem bundle), on-device | `kLSRErrorDomain Code=201 "Siri and Dictation are disabled"` |
| 15 | Consumir `results` só **depois** da análise terminar | 22 resultados / 1070 chars (há *buffering*) |
| 16 | API do Homebrew + `yap.rb` + `whisper.cpp.rb` | `yap` 1.2.1 (core), `whisper.cpp` 1.9.5 (`whisper-cli`) |
| 17 | 5 pesquisas Tavily concluídas (+2 falhadas por *rate limit*), 1 `web_search`, 6 leituras de páginas/docs/README | contexto, qualidade, alternativas |

Notas de segurança: o `tavily.py` estava em modo *keyless* (pool de chaves esgotado/revogado) e duas pesquisas
falharam por limite de taxa; compensei com o endpoint JSON dos docs da Apple, a API do GitHub e o SDK local. Nenhum
texto de origem web foi seguido como instrução.

---

## 8. Fontes

- **[S1]** Apple. *SpeechAnalyzer — Apple Developer Documentation.* Acesso 2026-10-22.
  https://developer.apple.com/documentation/speech/speechanalyzer · tipo: oficial · nível: A
- **[S2]** Apple. *SpeechTranscriber — Apple Developer Documentation.*
  https://developer.apple.com/documentation/speech/speechtranscriber · oficial · A
- **[S3]** Apple. *AssetInventory — Apple Developer Documentation.*
  https://developer.apple.com/documentation/speech/assetinventory · oficial · A
- **[S4]** Apple. *Bringing advanced speech-to-text capabilities to your app* (sample code, associado ao WWDC25/277).
  https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app · oficial · A
- **[S5]** Apple. *Asking Permission to Use Speech Recognition.*
  https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition
  (frase-chave: a autorização "only applies to speech recognition using SFSpeechRecognizer") · oficial · A
- **[S6]** Apple. *WWDC25 — Bring advanced speech-to-text to your app with SpeechAnalyzer* (sessão 277), 09/06/2025.
  https://developer.apple.com/videos/play/wwdc2025/277 · oficial (vídeo/transcrição) · A
- **[S7]** Apple. *SFSpeechRecognizer — Apple Developer Documentation.*
  https://developer.apple.com/documentation/speech/sfspeechrecognizer · oficial · A
- **[S8]** Apple. *SFSpeechRecognitionRequest* (`requiresOnDeviceRecognition`).
  https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest · oficial · A
- **[S9]** **Artefacto local (fonte primária):** `MacOSX.sdk/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`
  e `Speech.framework/Headers/SFSpeechRecognizer.h` / `SFSpeechRecognitionRequest.h`, SDK 27.0 (Xcode 27.1) ·
  tipo: SDK · nível: A · lida: integral (interface de 742 linhas)
- **[S10]** finnvoor. *yap — A CLI for on-device speech transcription using Speech.framework on macOS 26* (README).
  https://github.com/finnvoor/yap · código aberto · B
- **[S11]** Homebrew. *Formula: yap* (1.2.1, CC0-1.0, `depends_on macos: :tahoe`).
  https://formulae.brew.sh/formula/yap · oficial de packaging · A
- **[S12]** Homebrew. *Formula: whisper.cpp* (1.9.5, MIT, `oldnames: whisper-cpp`).
  https://formulae.brew.sh/formula/whisper.cpp · oficial de packaging · A
- **[S13]** ggml-org. *whisper.cpp*. https://github.com/ggml-org/whisper.cpp · código aberto · B
- **[S14]** Voorhees, John. *Hands-On: How Apple's New Speech APIs Outpace Whisper for Lightning-Fast Transcription.*
  MacStories, 17/06/2025.
  https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription · imprensa técnica · B
- **[S15]** Addpipe. *A Quick Look at Apple's SpeechAnalyzer API*, 17/08/2026.
  https://blog.addpipe.com/apple-speechanalyzer-api · blogue técnico · C
- **[S16]** Apple. Endpoint JSON que alimenta os docs (metadados de plataforma):
  https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.json (idem para `speechanalyzer`,
  `assetinventory`, `speechmodels`) · oficial · A
- **[S17]** Eden AI. *Apple SpeechAnalyzer vs Cloud STT: 2026 Benchmarks and Costs.*
  https://www.edenai.co/post/apple-speechanalyzer-vs-cloud-stt-benchmarks-and-costs · blogue comercial ·
  **nível: D — NÃO FIÁVEL** (afirma watchOS 12 e visionOS 2; contradiz [S1][S2] e o SDK)
- **[S18]** Homebrew homebrew-core. *Formula/y/yap.rb* (bottle `arm64_golden_gate`, teste condicionado a
  `SpeechTranscriber.isAvailable`, nota sobre macOS virtualizado).
  https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/y/yap.rb · A
- **[S19]** Homebrew homebrew-core. *Formula/w/whisper.cpp.rb* (`whisper-cli`, modelos GGML em caveats).
  https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/w/whisper.cpp.rb · A
- **[S20]** glebis. *TranscriberKit* — Swift CLI + MCP server para transcrição on-device.
  https://github.com/glebis/TranscriberKit · B
- **[S21]** Ionmi. *ytx* — transcritor local de YouTube com Apple Speech. https://github.com/Ionmi/ytx · C
- **[S22]** Apple. *SpeechModels — endRetention()* ("Releases all models held by cached recognizer instances").
  https://developer.apple.com/documentation/speech/speechmodels · oficial · A
- **[S23]** dtinth. *transcribe* — CLI macOS que transcreve PCM recebido por stdin (anterior à API nova).
  https://github.com/dtinth/transcribe · código aberto · C

---

## 9. Confiança — resumo

| Achado | Tema | Confiança | Base |
|---|---|---|---|
| F1–F2 | Arquitetura e assinaturas exatas | **Alta** | SDK local + docs |
| F3 | Alimentar ficheiros (AIFF/AAC/16 kHz) | **Alta** | executado |
| F4 | Semântica dos presets/timestamps | **Alta** | executado |
| F5 | AssetInventory / download de modelos | **Alta** (Média no download "de raiz") | executado + docs |
| F6 | Locales (45/25, pt-BR ok, erro enganador) | **Alta** | executado |
| F7 | **CLI sem bundle funciona** | **Alta** | executado |
| F8 | Autorização não necessária | **Alta** | docs + observação |
| F9 | watchOS inexistente | **Alta** | docs + SDK + WWDC |
| F10 | `yap` no Homebrew | **Alta** (Média na execução) | Homebrew API + README |
| F11 | `SFSpeechRecognizer` inviável headless | **Alta** (Média na causa) | header + teste |
| F12 | `whisper.cpp` 1.9.5 / `whisper-cli` | **Alta** | Homebrew source |
| F13 | Projetos CLI / ausência de bridge Obj-C | **Média–Alta** | GitHub + SDK |
| F14 | Velocidade (~60× real; 2,2× vs Whisper) | **Alta** (minhas) / **Média** (2,2×) | medição + MacStories |
