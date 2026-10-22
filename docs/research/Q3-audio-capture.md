---
id: Q3
titulo: "Q3 — Captura de áudio no relógio (VoiceRecorder.swift vs SDK watchOS 27)"
tipo: pesquisa-q3
versao: 2
criado: 2026-10-22
estado: respondida
confianca-global: high
maquina-de-verificacao: "Mac mini M1 (arm64, T8103) · macOS 27.0 build 26A428 · Xcode 27.1 (27A9269) · WatchOS27.0.sdk"
alvo: "apps/watch/WatchPilot/Audio/VoiceRecorder.swift (deployment target watchOS 11.0, Swift 5.0, SWIFT_STRICT_CONCURRENCY=minimal)"
metodo: "Leitura integral dos headers do WatchOS27.0.sdk instalado (fonte de verdade) + endpoints JSON de documentação da Apple + 2 builds xcodebuild -sdk watchos27.0 (antes/depois)"
---

# Q3 — Captura de áudio no relógio (VoiceRecorder.swift vs SDK watchOS 27)

> **Escopo.** O `VoiceRecorder` grava um comando de voz de poucos segundos como AAC 16 kHz mono e
> entrega o ficheiro ao `AssistantController` para upload. Este relatório verifica essa implementação
> contra o **SDK watchOS 27.0 instalado nesta máquina** e contra a documentação oficial, e corrige o
> que está errado.
>
> **Legenda de confiança.** **[high]** verificado directamente nos headers do SDK instalado e/ou na
> documentação Apple actual. **[moderate]** uma fonte autoritativa, ou inferência com uma pequena
> lacuna. **[low]** apenas evidência indirecta/comunitária.
>
> **Fontes.** `[S#]` → §9. Os headers do SDK entram como fonte primária *com caminho e linha*, porque
> são o que o compilador e o sistema em execução realmente vêem em watchOS 27.

**Veredicto em uma frase:** a implementação **compila** contra o SDK watchOS 27.0 e os seus tipos,
categorias, opções e settings estão **correctos** (`AVAudioRecorder` existe em watchOS desde a 4.0),
mas tinha **dois defeitos reais de sessão de áudio** — um de ordem (activar → desactivar → `record()`)
e um de fuga (sessão activa e microfone aberto depois de um arranque falhado) — ambos corrigidos e
provados com build. O comportamento de pulso em baixo (§4) é uma **propriedade do sistema**, não um bug
do código, mas obriga a uma decisão de produto: sem o *Audio background mode* no Info.plist a captura
**não** continua com o pulso em baixo.

---

## 0. Resposta executiva

1. **`AVAudioRecorder` está totalmente disponível em watchOS 27** — desde watchOS 4.0, incluindo
   `isMeteringEnabled`, `updateMeters()`, `averagePower(forChannel:)` e `peakPower(forChannel:)`, que
   não têm macro de disponibilidade própria e herdam a da classe. **[high]** [S1][S2][S3][S4][S5]
2. **Os settings estão correctos**: `kAudioFormatMPEG4AAC` + 16 000 Hz + 1 canal + 48 kbps + `.m4a` é
   uma combinação válida; não existe **nenhuma** restrição específica de watchOS nos headers nem na
   documentação. Nota: não se pode impor a taxa de hardware no relógio (`setPreferredSampleRate` é
   `API_UNAVAILABLE(watchos)`), a reamostragem para 16 kHz é feita pelo encoder. **[high]** [S6][S7][S8][S9]
3. **`setCategory(.playAndRecord, mode: .default, options: [.duckOthers])` é válido em watchOS**: a
   categoria e o modo existem desde watchOS 2.0 e `.duckOthers` é explicitamente válido com
   *PlayAndRecord* + *ModeDefault*. `setActive(true)` **é necessário** e está disponível desde watchOS
   2.0. Existe modo de falha documentado: arrancar I/O de áudio a partir do background →
   `AVAudioSessionErrorCodeCannotStartPlaying` (`'!pla'`, 561015905) e, com sessão *mixable* (que
   `.duckOthers` implica), `AVAudioSessionErrorCodeCannotStartRecording` (`'!rec'`, 561145187).
   **[high]** [S10][S11][S12][S13][S14][S15]
4. **A gravação NÃO continua com o pulso em baixo** com a configuração actual. O `physical-therapy`
   mantém o *processo* vivo até 1 h (é um session type *background*, não *frontmost*), mas o microfone
   em background exige o *Audio background mode*, que o Info.plist **não declara** (só `fetch`).
   O relatório prescreve a correcção e um teste que a confirma (§4, §8). **[high]** para a suspensão
   / **[moderate-high]** para o corte do microfone sem o background mode.
5. **Armadilhas confirmadas**: extensão `.m4a` ↔ `kAudioFormatMPEG4AAC` (inferência por extensão, e
   *overwrite* do ficheiro existente); `prepareToRecord()` é redundante mas benéfico; a callback do
   delegate **não é chamada** quando a gravação é cortada por interrupção. **[high]** [S2][S16][S17]
6. **Compila** — `xcodebuild -sdk watchos27.0` deu `** BUILD SUCCEEDED **` antes e depois das
   correcções, para arm64 **e** arm64_32, com **zero** avisos atribuíveis a `VoiceRecorder.swift`.
   **[high]** (§6)

---

## 1. `AVAudioRecorder` em watchOS 27

| Símbolo | Disponibilidade no header | Linha |
| --- | --- | --- |
| `@interface AVAudioRecorder` | `API_AVAILABLE(macos(10.7), ios(3.0), **watchos(4.0)**, tvos(17.0))` | `AVAudioRecorder.h:22` [S1] |
| `-initWithURL:settings:error:` | sem macro → herda a da classe (watchOS 4.0) | `AVAudioRecorder.h:33` [S1] |
| `-initWithURL:format:error:` | `watchos(4.0)` explícito | `AVAudioRecorder.h:40` [S1] |
| `prepareToRecord` / `record` / `stop` / `deleteRecording` | sem macro → watchOS 4.0 | `AVAudioRecorder.h:50,57,91,98` [S1] |
| `isMeteringEnabled` | **sem macro** → watchOS 4.0 | `AVAudioRecorder.h:155` [S2] |
| `updateMeters()` | **sem macro** → watchOS 4.0 | `AVAudioRecorder.h:161` [S3] |
| `peakPower(forChannel:)` | **sem macro** → watchOS 4.0 | `AVAudioRecorder.h:167` [S4] |
| `averagePower(forChannel:)` | **sem macro** → watchOS 4.0 | `AVAudioRecorder.h:173` [S5] |
| `channelAssignments` | `ios(7.0), watchos(4.0)` + `API_UNAVAILABLE(macos)` | `AVAudioRecorder.h:180` [S1] |
| `format`, `deviceCurrentTime` | `watchos(4.0)` explícito | `AVAudioRecorder.h:126,146` [S1] |
| `@protocol AVAudioRecorderDelegate` | `watchos(4.0)`, e `NS_SWIFT_SENDABLE` | `AVAudioRecorder.h:188-190` [S17] |

**Nenhum** destes membros tem `__WATCHOS_PROHIBITED`, `API_UNAVAILABLE(watchos)` ou deprecação no SDK
instalado. Os quatro símbolos de medição — os únicos que a orb usa a 30 Hz — não têm macro nenhuma,
portanto a disponibilidade é exactamente a da classe: **watchOS 4.0+**, ou seja, o deployment target
11.0 do projecto está confortavelmente acima. **[high]** [S1][S2][S3][S4][S5]

Um detalhe que confirma que a API é de primeira classe no relógio: `AVAudioRecorder` tem
`watchos(4.0)` na classe **mas** `AVAudioSession` é ainda mais antiga (`watchos(2.0)`,
`AVAudioSession.h:31,38`), e ambas continuam a receber API nova em 27.0 (ex.: notificações
`didBecomeActive`/`didBecomeInactive`, `AVAudioSessionTypes.h:311-321`). **[high]** [S10][S13]

---

## 2. Os settings de gravação (16 kHz mono AAC, 48 kbps)

Settings actuais (`VoiceRecorder.swift:44-50`):

```swift
AVFormatIDKey: Int(kAudioFormatMPEG4AAC),   // 'aac ' = 0x61616320
AVSampleRateKey: 16_000.0,                  // Double, Hz
AVNumberOfChannelsKey: 1,                   // Int
AVEncoderBitRateKey: 48_000,                // Int, bits/s (não por canal)
AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
```

Verificação:

* **`AVFormatIDKey`, `AVSampleRateKey`, `AVNumberOfChannelsKey`, `AVEncoderBitRateKey`,
  `AVEncoderAudioQualityKey`** estão todas disponíveis em watchOS **3.0** (`AVAudioSettings.h:17,18,19,37,33`),
  portanto acima do mínimo do recorder; `AVEncoderBitRateKey` conta bits por segundo **totais**
  (`AVAudioSettings.h:36`), logo `48_000` = 48 kbps no canal único. **[high]** [S6][S9]
* **`kAudioFormatMPEG4AAC`** é o FourCC `'aac '` (= `0x61616320`), um membro do enum `AudioFormatID`
  em `CoreAudioBaseTypes.h:397` — sem macro de disponibilidade, logo disponível em todas as
  plataformas suportadas, **incluindo watchOS**. Existe no SDK watchOS 27.0 instalado. **[high]** [S7][S8]
* **A combinação é coerente**: AAC-LC aceita 16 000 Hz (é uma das taxas canónicas do encoder) e 48 kbps
  num único canal está dentro do intervalo suportado. Não há **nenhum** aviso de restrição de
  sample-rate/bitrate nos headers do SDK para watchOS, e a documentação Apple não documenta nenhuma.
  **[high]** [S6][S7]
* **A taxa de 16 kHz não pode ser imposta ao hardware**: `setPreferredSampleRate:`,
  `setPreferredIOBufferDuration:` e `setPreferredInputNumberOfChannels:` são
  `API_UNAVAILABLE(watchos, macos)` (`AVAudioSession.h:305,310,314`). O caminho correcto — que o código
  segue — é **não** os chamar e deixar o encoder do `AVAudioRecorder` reamostrar. Tentar forçar a taxa
  no hardware seria, no mínimo, um `false`/erro silencioso. **[high]** [S11]
* **Mono é o correcto**: o microfone embutido do relógio é 1 canal
  (`maximumInputNumberOfChannels`, `AVAudioSession.h:335`, disponível em watchOS); pedir 1 canal evita
  qualquer negociação estéreo. **[moderate]** [S11]
* **Extensão e container**: o header diz explicitamente que o tipo de ficheiro *"will be inferred from
  the file extension"* quando não se usa `AVAudioFileTypeKey` (`AVAudioRecorder.h:31`) —
  `.m4a` + `kAudioFormatMPEG4AAC` = MPEG-4 Audio, que é o par correcto. E, no mesmo parágrafo:
  *"Will overwrite a file at the specified url if a file exists."* → o nome com timestamp ISO-8601
  truncado ao segundo pode colidir em dois takes no mesmo segundo, e o segundo **substitui** o
  primeiro. Como a intenção declarada é "replacing any previous take", é aceitável; fica registado.
  **[high]** [S2]

**Nada a corrigir neste ponto.**

---

## 3. `AVAudioSession` — categoria, modo, opções, activação

```swift
try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
try session.setActive(true, options: [])
```

| Alegação | Verificação | Confiança |
| --- | --- | --- |
| `.playAndRecord` existe em watchOS | `AVAudioSessionCategoryPlayAndRecord`, `ios(3.0), **watchos(2.0)`** — `AVAudioSessionTypes.h:109` [S10] | **[high]** |
| `.default` existe em watchOS | `AVAudioSessionModeDefault`, `ios(5.0), **watchos(2.0)`** — `AVAudioSessionTypes.h:139` [S10] | **[high]** |
| `.duckOthers` é válido nesta combinação | *"DuckOthers is only valid with AVAudioSessionCategoryAmbient, **AVAudioSessionCategoryPlayAndRecord**, AVAudioSessionCategoryPlayback, and AVAudioSessionCategoryMultiRoute **with AVAudioSessionModeDefault**"* — `AVAudioSessionTypes.h:496-499` [S12] | **[high]** |
| `.duckOthers` existe em watchOS | enum `AVAudioSessionCategoryOptions` introduzido em *"iOS 6.0 / watchOS 2.0 / tvOS 9.0"*, e o valor `= 0x2` não tem `API_UNAVAILABLE` — `AVAudioSessionTypes.h:455-461,499` [S12] | **[high]** |
| `setActive(true)` é necessário e existe | `setActive:withOptions:error:` `ios(6.0), **watchos(2.0)`** — `AVAudioSession.h:265`; a sessão por omissão *"supports audio playback, but **disallows audio recording**"* até se mudar a categoria [S18] | **[high]** |

**Que opções existem em watchOS** (e o que *não* existe — útil para não "corrigir" para algo proibido):

| Opção | watchOS | Linha |
| --- | --- | --- |
| `.mixWithOthers` (0x1) | ✅ | `AVAudioSessionTypes.h:482` [S12] |
| `.duckOthers` (0x2) | ✅ (e **implica** `.mixWithOthers`) | `AVAudioSessionTypes.h:493-499` [S12] |
| `.allowBluetoothHFP` (0x4) | ✅ watchOS 11.0 | `AVAudioSessionTypes.h:520` [S12] |
| `.defaultToSpeaker` (0x8) | ❌ `API_UNAVAILABLE(tvos, watchos, macos)` | `AVAudioSessionTypes.h:531` [S12] |
| `.interruptSpokenAudioAndMixWithOthers` (0x11) | ✅ watchOS 2.0 | `AVAudioSessionTypes.h:549` [S12] |
| `.allowBluetoothA2DP` (0x20) | ✅ watchOS 3.0 | `AVAudioSessionTypes.h:572` [S12] |
| `.allowAirPlay` (0x40) | ❌ `API_UNAVAILABLE(watchos)` | `AVAudioSessionTypes.h:578` [S12] |
| `.overrideMutedMicrophoneInterruption` (0x80) | ✅ watchOS 7.3 | `AVAudioSessionTypes.h:598` [S12] |
| `.farFieldInput`, `.bluetoothHighQualityRecording` | ❌ indisponíveis em watchOS | `AVAudioSessionTypes.h:612,635` [S12] |

Notas de alto valor:

* **`.duckOthers` implica `mixWithOthers`** (`AVAudioSessionTypes.h:493-494`: *"Setting this option will
  also make your session mixable with others"*). Consequência não óbvia: a sessão passa a ser
  *mixable*, e o SDK diz que uma gravação *mixable* iniciada a partir do background é recusada com
  `AVAudioSessionErrorCodeCannotStartRecording` (`'!rec'`, 561145187) — `AudioSessionTypes.h:63-65,91`.
  Ou seja: **nunca** tentar (re)iniciar a gravação em background com esta configuração. Hoje o código só
  grava em foreground, portanto está correcto. **[high]** [S14]
* **Modo de falha documentado quando a app não é frontmost**: `AVAudioSessionErrorCodeCannotStartPlaying`
  (`'!pla'`, 561015905) — *"The app is not allowed to start recording and/or playing, usually because
  of a **lack of audio key in its Info.plist**"* (`AudioSessionTypes.h:58-62,90`). Este é o código que
  se vê no relógio quando se tenta captar áudio sem o *Audio background mode* (§4, §8). **[high]** [S15]
* **Ordem de desactivação**: o header exige parar todo o I/O **antes** de `setActive(false)` — desde
  iOS 8 que desactivar com I/O a correr devolvia `AVAudioSessionErrorCodeIsBusy` (`'!act'`,
  `AudioSessionTypes.h:85`), e desde iOS/watchOS 26 isso deixou de devolver erro (`AVAudioSession.h:242-262`).
  O código faz `recorder.stop()` **antes** de desactivar — correcto. **[high]** [S11][S14]
* `.notifyOthersOnDeactivation` continua válido em watchOS 27 (`AVAudioSessionSetActiveOptions`,
  `AVAudioSessionTypes.h:703-708`, *"Only valid on session deactivation"*). O tipo novo de 27.0
  `AVAudioSessionDeactivationOptions` (`AVAudioSessionTypes.h:408`) ainda não substitui o antigo.
  **[high]** [S12]

---

## 4. Pulso em baixo — o que acontece *mesmo*

Esta é a pergunta que mais muda o desenho do produto, por isso a resposta é separada em três factos.

**(a) O `physical-therapy` mantém o *processo* vivo; não é este o problema. [high]**
Apple: *"An app running on Apple Watch normally transitions to the background and becomes suspended
when the user lowers their wrist"*, e a tabela de session types diz que `physical-therapy` é
**Background** (não *Frontmost*), com limite de 1 h; *"Background sessions continue to run in the
background, even if the user dismisses the app or launches another app"* [S19]. O
`WKExtendedRuntimeSession.h:45` só invalida por `ResignedFrontmost` nos tipos *frontmost*
(`self-care`, `mindfulness`), e o `:48` (`SuppressedBySystem`) é o caso do sistema negar o tipo.
Portanto: com a sessão `physical-therapy` a correr, o processo **não** é suspenso e o `RuntimeCoordinator`
continua a poder agendar trabalho. **[high]** [S19][S20]

**(b) O microfone, esse, não segue o processo. [moderate-high]**
O que a Apple lista como possível *"even after the watch's screen turns off"* é: *"continue to
communicate with a Bluetooth device, process data, or **play** sounds or haptics"* — **captar** áudio
não está na lista [S19][S21]. E o caminho de erro do SDK é explícito: começar a captar/ reproduzir em
background exige uma *"audio key"* no Info.plist, sob pena de `'!pla'` (561015905)
(`AudioSessionTypes.h:58-62`). O Info.plist actual declara:

```xml
<key>UIBackgroundModes</key><array><string>fetch</string></array>   <!-- sem "audio" -->
```

Consequência prevista: ao baixar o pulso o sistema desactiva/interrompe a sessão de áudio e a captura
**pára** — o ficheiro em `Documents/InProgress/` fica com o que foi gravado até aí (é exactamente por
isso que a escolha de `Documents/` em vez de `tmp/` está certa), mas o microfone **fecha**.
**[moderate-high]** — não há relógio físico nesta máquina para confirmar em execução; o teste que
confirma está em §8.

**(c) A app não se apercebe, e isso é um problema real de UX. [high]**
O header do delegate diz, na letra: *"This method is NOT called if the recorder is stopped due to an
interruption."* (`AVAudioRecorder.h:196`). Ou seja, quando o pulso cai e o sistema corta a gravação, o
`audioRecorderDidFinishRecording` **não** dispara. O `normalizedPower()` passa a devolver 0 (o
`isRecording` é falso) e a orb fica "morta" — mas o `phase` continua `.listening` para sempre, um
comando vivo que já não está a gravar nada. **[high]** [S17]

**O que a app devia fazer** (recomendação, não aplicada porque é decisão de produto — §8):

1. **Se a captura com pulso em baixo é requisito:** declarar `UIBackgroundModes` = `audio` (o *Audio
   background mode*, a mesma alavanca já mapeada em `[Q2 §0.7](Q2-watchos-background.md)`), mantendo
   o `physical-therapy` apenas para a janela de 1 h. Custo: indicador de gravação na barra de estado,
   escrutínio de App Review ("a app tem de produzir áudio"), e consumo de bateria.
2. **Se não é requisito (recomendado para um comando de 3–5 s):** tratar o pulso em baixo como *fim de
   captura* — passar a observar `AVAudioSession.didBecomeInactiveNotification` (nova em watchOS 27,
   `AVAudioSessionTypes.h:311-321`; substitui `interruptionNotification`, **deprecada** de
   `watchos(2.0, 27.0)` em `AVAudioSessionTypes.h:229`) e, ao recebê-la, parar + fazer upload do que
   existe, com um estado de UI honesto ("gravação terminou"). **[high]** [S12]

---

## 5. Armadilhas conhecidas (verificadas)

| Armadilha | O que o SDK diz | Estado no código | Confiança |
| --- | --- | --- | --- |
| **Extensão vs container** | Tipo inferido da extensão quando `AVAudioFileTypeKey` está ausente; *overwrite* do ficheiro existente (`AVAudioRecorder.h:31`) | `.m4a` + AAC = par correcto; overwrite é intencional | **[high]** [S2] |
| **`prepareToRecord()` vs `record()`** | `prepareToRecord` *"is called automatically on record"* (`AVAudioRecorder.h:48`) — chamá-lo à mão é redundante **mas** faz falhar cedo a configuração do encoder | manter: o `guard` actual dá erro explícito em vez de um `record()` a devolver `false` | **[high]** [S1] |
| **Delegate em interrupção** | `audioRecorderDidFinishRecording` **não** é chamada quando a paragem vem de interrupção (`AVAudioRecorder.h:196`); `audioRecorderEncodeErrorDidOccur` cobre erros de encoding (`:205`) | não tratado — ver §4(c) e §7/D3 | **[high]** [S17] |
| **`kAudioFormatMPEG4AAC` em watchOS** | `'aac '` em `CoreAudioBaseTypes.h:397`, sem restrição de plataforma | correcto | **[high]** [S7] |
| **Delegate é `weak`** | `@property(weak, ...) delegate` (`AVAudioRecorder.h:132`) | ok: `VoiceRecorder` é guardado por `AssistantController` (`private let recorder`) | **[high]** [S1] |
| **Thread do delegate** | `AVAudioRecorderDelegate` é `NS_SWIFT_SENDABLE` (`AVAudioRecorder.h:188`); as callbacks chegam fora do main actor | `VoiceRecorder` não é `@MainActor` e escreve `self.recorder` numa callback — compila porque o projecto está em **Swift 5.0 + strict concurrency `minimal`**; em Swift 6 isto é erro | **[high]** [S17] + `project.pbxproj` |
| **Custo da medição** | `isMeteringEnabled` liga o cálculo de potência por buffer; a Apple avisa que CPU sustentada pode cancelar a extended runtime session | 30 Hz é aceitável, mas a orb deve continuar a ser o único consumidor | **[moderate]** [S19] |

---

## 6. Prova de compilação

Comando (idêntico ao pedido), a partir de `apps/watch`:

```bash
xcodebuild -project WatchPilot.xcodeproj -scheme WatchPilot -sdk watchos27.0 \
  -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath /Volumes/Ext2TB/Caches/Xcode-DerivedData/watchpilot-dd build
```

| Momento | Resultado |
| --- | --- |
| **Antes** de qualquer alteração | `** BUILD SUCCEEDED **` (exit 0) |
| **Depois** das correcções de §7 | `** BUILD SUCCEEDED **` (exit 0) |

Saída relevante da segunda compilação: `SwiftCompile normal arm64 Compiling VoiceRecorder.swift` e
`SwiftCompile normal arm64_32 Compiling VoiceRecorder.swift` — compila para as duas arquitecturas do
relógio. **Zero** `warning:`/`error:` atribuíveis a `VoiceRecorder.swift`. Os únicos avisos do
projecto são pré-existentes e alheios a este ficheiro:
`AssistantController.swift:222` (valor `saved` não usado) e `WatchPilotApp.swift:21` (`async` sem
`await`, erro só em modo Swift 6). Contexto de compilação: `WATCHOS_DEPLOYMENT_TARGET = 11.0`,
`SWIFT_VERSION = 5.0`, `SWIFT_STRICT_CONCURRENCY = minimal`, `PRODUCT_BUNDLE_IDENTIFIER =
me.kluser.watchpilot`. **[high]**

---

## 7. Defeitos encontrados e corrigidos em `VoiceRecorder.swift`

Ambos são de **sessão de áudio**, ambos invisíveis ao compilador, ambos silenciosos em runtime.

### D1 — `start()` desactivava a sessão que acabara de activar  **[alto]**

Código original: `setCategory` → `setActive(true)` → **`stop(discardFile: true)`** → criar recorder →
`record()`. E `stop(discardFile:)` termina com `setActive(false, options: [.notifyOthersOnDeactivation])`.
Ou seja, quando existia um take anterior, a sessão era activada e imediatamente desactivada antes de
`record()` — a gravação corria (ou não) com a sessão inactiva e o `.duckOthers` perdia-se. A intenção
("acabar o take anterior primeiro") estava certa; a ordem é que era auto-contraditória.

```diff
 func start() throws {
+    // Finish the previous take *before* touching the session: `stop(discardFile:)`
+    // ends with `setActive(false)` ...
+    stop(discardFile: true)
+
     let session = AVAudioSession.sharedInstance()
     do {
         try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
         try session.setActive(true, options: [])
     } catch { throw Failure.session(error.localizedDescription) }
-
-    stop(discardFile: true)
-
     let url = try Self.newRecordingURL()
```

### D2 — arranque falhado deixava o microfone aberto e o áudio dos outros "duckado"  **[alto]**

Se `setActive(true)` conseguisse e o resto falhasse (`AVAudioRecorder(url:settings:)` a lançar,
`prepareToRecord()`/`record()` a devolver `false`), o `throw` subia até ao `AssistantController`, que
mostra `.failed` — e ninguém desactivava a sessão: `stop()` sai com `guard let recorder else { return
nil }` e não há outro sítio na app que chame `setActive(false)`. Resultado: microfone aberto (com
indicador), áudio de outras apps atenuado indefinidamente, bateria a arder.

```diff
         } catch let failure as Failure {
+            // Never leave the microphone open — nor other audio ducked by `.duckOthers` —
+            // when the start fails after the session was activated.
+            Self.deactivateSession()
             throw failure
         } catch {
+            Self.deactivateSession()
             throw Failure.recorder(error.localizedDescription)
         }
```

Com um único ponto de desactivação, partilhado com `stop()`:

```swift
private static func deactivateSession() {
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
}
```

Ambas as correcções respeitam a regra do header (I/O parado **antes** de desactivar:
`AVAudioSession.h:242-262`) e mantêm `.notifyOthersOnDeactivation`, que desfaz o `ducking` dos outros
sons — `AVAudioSessionTypes.h:703-708`. Sem alterações de assinatura pública.

---

## 8. Achados fora de `VoiceRecorder.swift` (não corrigidos — decisão do produto)

Registados aqui porque são a causa provável do comportamento de §4 e envolvem Info.plist/capabilities,
que este trabalho não devia alterar discricionariamente.

| # | Achado | Severidade | Confiança |
| --- | --- | --- | --- |
| **P1** | `UIBackgroundModes` só declara `fetch` — falta **`audio`**. Sem o *Audio background mode* a captura em background é recusada (`AVAudioSessionErrorCodeCannotStartPlaying`, `'!pla'`, 561015905) e o microfone fecha com o pulso em baixo. Correção: acrescentar `<string>audio</string>`. | alta (só se a captura em pulso em baixo for requisito) | **[moderate-high]** [S15][S19][S22] |
| **P2** | `WKBackgroundModes = physical-therapy` é usado *pelo runtime*, não pelo propósito. Apple: *"Select a session type based on the app's intended use—not based on the features that the session provides."* | média (risco de App Review) | **[high]** [S19] |
| **P3** | `UIBackgroundModes` `fetch` e `BGTaskSchedulerPermittedIdentifiers` (chave iOS-only; `BGTaskScheduler` é `API_UNAVAILABLE(watchos)`) não fazem nada no relógio — o refresh é via `WKApplication.scheduleBackgroundRefresh`. Ruído inofensivo. | baixa | **[high]** [S23] |
| **P4** | Nenhum observador de `AVAudioSession.didBecomeInactiveNotification`; o delegate não cobre interrupção (§4c). `phase` fica `.listening` com a gravação morta. | média (UX) | **[high]** [S12][S17] |
| **P5** | `finishRecordingAndSend()` faz upload mesmo quando a captura tem poucos milissegundos (m4a só com header) — melhor validar `recorder.currentTime`/tamanho antes do upload. | baixa | **[moderate]** |
| **P6** | `VoiceRecorder` não é `@MainActor` e o delegate escreve estado fora do main actor; com `SWIFT_VERSION 6.0` isto falha a compilação (`NS_SWIFT_SENDABLE`). | baixa (dívida) | **[high]** [S17] |

---

## 9. Fontes

**SDK instalado — `WatchOS27.0.sdk` (fonte de verdade; caminho completo a partir de
`/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS27.0.sdk/`)**

- **[S1]** `System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioRecorder.h` — lido na íntegra
  (243 linhas): disponibilidade da classe e de cada membro (linhas 22, 33, 40, 50, 57, 91, 98, 126,
  132, 146, 180), semi-redundância de `prepareToRecord` (48), inferência de container/overwrite (31),
  delegate `weak` (132).
- **[S2]** `AVAudioRecorder.h:31` — *"The file type to create can be set through the corresponding
  settings key. If not set, it will be inferred from the file extension. Will overwrite a file at the
  specified url if a file exists."* (container/`.m4a`).
- **[S3]** `AVAudioRecorder.h:155,161` — `isMeteringEnabled`, `updateMeters` **sem** macro de
  disponibilidade (herdam watchOS 4.0).
- **[S4]** `AVAudioRecorder.h:167` — `peakPowerForChannel:` sem macro.
- **[S5]** `AVAudioRecorder.h:173` — `averagePowerForChannel:` sem macro.
- **[S6]** `AVFAudio.framework/Headers/AVAudioSettings.h` — linhas 17, 18, 19, 30, 33, 36, 37: todas as
  chaves usadas têm `watchos(3.0)`; `AVEncoderBitRateKey`/`AVEncoderBitRatePerChannelKey` mutuamente
  exclusivos (36).
- **[S7]** `CoreAudioTypes.framework/Headers/CoreAudioBaseTypes.h:397` — `kAudioFormatMPEG4AAC = 'aac '`
  (doc do enum em :304).
- **[S8]** Ausência de restrição: grep sistemático por `WATCHOS_PROHIBITED` / `API_UNAVAILABLE(watchos)`
  nos headers de AVFAudio — nenhum toca `AVAudioRecorder`; `kAudioFormatMPEG4AAC` não tem macro em
  watchOS 27.0.
- **[S9]** `AVAudioSettings.h:36-37` — *"only one of AVEncoderBitRateKey and AVEncoderBitRatePerChannelKey
  should be provided"*; `AVEncoderBitRateKey` é bits por segundo **totais** (não por canal) — o valor
  `48_000` do código é, portanto, 48 kbps no único canal.
- **[S10]** `AVFAudio.framework/Headers/AVAudioSessionTypes.h` — categorias e modos: `PlayAndRecord`
  `:109`, `ModeDefault` `:139` (ambos `watchos(2.0)`).
- **[S11]** `AVFAudio.framework/Headers/AVAudioSession.h` — classe `:31,38` (watchos 2.0); `setCategory`
  `:46-77`; `setMode` `:106-108`; `setActive` `:264,265`; discussão activação/desactivação `:242-262`
  (`IsBusy`, mudança em iOS 26); **indisponíveis em watchOS**: `setPreferredSampleRate` `:305`,
  `setPreferredIOBufferDuration` `:310`, `setPreferredInputNumberOfChannels` `:314`,
  `setInputGain` `:351`; `maximumInputNumberOfChannels` `:335`; `isInputAvailable` `:360`.
- **[S12]** `AVAudioSessionTypes.h` — introdução das opções em iOS 6.0/watchOS 2.0 `:455-461`;
  `mixWithOthers` `:482`; `duckOthers` + regra de validade + implicação de mixable `:493-499`;
  lista de opções indisponíveis em watchOS `:531,578,612,635`; `allowBluetoothHFP` `:520`;
  `overrideMutedMicrophoneInterruption` `:598`; `AVAudioSessionSetActiveOptions` `:703-708`;
  `AVAudioSessionDeactivationOptions` (27.0) `:408`; notificações novas de 27.0 `:311-321`;
  `interruptionNotification` deprecada `watchos(2.0,27.0)` `:229`; `portOverrideSpeaker`
  indisponível em watchOS `:417`.
- **[S13]** `AVAudioSessionTypes.h:311-321` — `didBecomeActiveNotification` /
  `didBecomeInactiveNotification` / `resumptionRecommendationNotification`, todas `watchos(27.0)`.
- **[S14]** `CoreAudioTypes.framework/Headers/AudioSessionTypes.h` — `AVAudioSessionErrorCode`:
  `IsBusy '!act'` `:85`; `CannotStartPlaying '!pla'` (561015905) `:58-62,90`; `CannotStartRecording
  '!rec'` (561145187) `:63-65,91`; `CannotInterruptOthers '!int'` `:50-52`.
- **[S15]** `AudioSessionTypes.h:58-62` — *"…usually because of a lack of audio key in its Info.plist."*
  (é a base da previsão de §4b e do achado P1).
- **[S16]** `AVAudioRecorder.h:48` — `prepareToRecord` *"is called automatically on record. Returns
  YES on success and NO on failure"*; `:91` — `stop` *"also closes the output file"* (razão pela qual
  o ficheiro fica íntegro mesmo quando a captura é cortada).
- **[S17]** `AVAudioRecorder.h:186-205` — `NS_SWIFT_SENDABLE` (`:188`), disponibilidade do protocolo
  `watchos(4.0)` (`:189-190`), **`audioRecorderDidFinishRecording` não é chamada em interrupção**
  (`:196`), `audioRecorderEncodeErrorDidOccur` (`:205`).

**WatchKit — `WatchOS27.0.sdk/System/Library/Frameworks/WatchKit.framework/Headers/WKExtendedRuntimeSession.h`**

- **[S20]** Lido na íntegra (186 linhas): `ResignedFrontmost` `:45`, `SuppressedBySystem` `:48`,
  `MustBeActiveToStartOrSchedule` `:58`, `startAtDate` só para alarm `:126`, sessão criada *"with the
  capabilities granted for the appropriate session type specified in the Background Modes
  capability"* `:82`.

**Documentação Apple (endpoints JSON de developer.apple.com, texto renderizado)**

- **[S19]** *Using extended runtime sessions.* https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions
  — *"An app running on Apple Watch normally transitions to the background and becomes suspended when
  the user lowers their wrist"*; tabela de session types (physical therapy = **Background**, 1 h);
  *"Extended runtime sessions let the app continue to communicate with a Bluetooth device, process
  data, or play sounds or haptics, even after the watch's screen turns off"*; *"Select a session type
  based on the app's intended use—not based on the features that the session provides"*; aviso de
  cancelamento por CPU sustentada. Lido na íntegra.
- **[S21]** *WKExtendedRuntimeSession.* https://developer.apple.com/documentation/watchkit/wkextendedruntimesession
  — mesma frase sobre Bluetooth/dados/som/háptica com o ecrã desligado; um único session type por app.
- **[S22]** *UIBackgroundModes.* https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes
  — metadados: `iOS 4.0 / iPadOS 4.0 / watchOS 4.0 / visionOS 1.0` (a chave é válida no relógio).
- **[S23]** *Background execution* / `BGTaskScheduler` — ver `[Q2 §9]` [S2][S18] deste repositório
  (`BGTaskScheduler` é `API_UNAVAILABLE(watchos)`; o refresh no relógio é
  `WKApplication.scheduleBackgroundRefresh`).
- **[S18]** *AVAudioSession.* https://developer.apple.com/documentation/avfaudio/avaudiosession —
  *"All iOS, tvOS, and watchOS apps have a default audio session … It supports audio playback, but
  **disallows audio recording**."* (razão pela qual `setCategory` + `setActive` são obrigatórios).

**Vizinhança neste repositório**

- `[Q2](Q2-watchos-background.md)` — contrato de execução em background (session types, orçamento de
  refresh, Audio background mode + `.longFormAudio`). Não contraditado por este relatório; §4 e P1
  alinham-se com o quadro de Q2.

---

## 10. Método e notas de integridade

* **Ordem de trabalho.** (1) leitura do código e do Info.plist; (2) headers do SDK instalado, lidos
  linha a linha, como fonte de verdade para disponibilidade; (3) documentação Apple via endpoints JSON
  (`developer.apple.com/tutorials/data/documentation/...`) porque o HTML das forums bloqueia
  fetching automatizado; (4) build de referência; (5) correcções; (6) build de prova.
* **Tavily não foi usada** para conclusões: o `web_search` devolveu apenas URLs (sem resposta
  sintetizada) e os fóruns Apple/Stack Overflow bloquearam o fetch (verificação anti-bot). Nenhuma
  conclusão deste relatório depende de conteúdo comunitário — todas as linhas `[S#]` são headers
  locais ou documentação Apple oficial.
* **O que não foi verificado em execução.** Não há Apple Watch físico ligado a esta máquina, portanto
  **nenhuma** afirmação sobre comportamento em runtime (fecho do microfone, valor exacto do erro,
  duração da sessão) foi observada — são inferidas dos headers e da documentação e estão marcadas como
  tal. Teste que fecha a lacuna: correr no relógio com o Console do Xcode aberto, iniciar a gravação,
  baixar o pulso e procurar (a) `AVAudioSessionErrorCodeCannotStartPlaying` / `561015905` e
  (b) se o ficheiro em `Documents/InProgress/` pára de crescer. Com e sem `UIBackgroundModes = audio`.
* **Limite de alterações.** Só `apps/watch/WatchPilot/Audio/VoiceRecorder.swift` foi modificado
  (D1, D2). Info.plist/capabilities (P1–P3) e o tratamento de interrupção (P4–P6) **não** foram
  tocados: são decisões de produto e estão documentados acima com a correcção proposta.
* **Estado do repositório.** A árvore não tem commits (`git status` lista tudo como `untracked`), pelo
  que não há `git diff` para citar; as alterações são as duas mostradas em §7.
