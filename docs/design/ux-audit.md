# Auditoria UX/UI — watch-pilot (app watchOS, ecrã único)

**Nota: 43/100 · Banda: `fair` (40–64)**

Interface: app watchOS standalone, ecrã único, seis estados (idle, listening, thinking/waiting, answer, error, live-hub), 184×224 pt (Apple Watch SE 40 mm).
Método: framework `uxui-evaluator` aplicado a partir de conhecimento interno — **não houve enriquecimento por API** (`UXUI_API_KEY` não existe neste ambiente, logo `api_enriched: false`, sem citações nem `business_impact`). Cada achado foi **verificado no código SwiftUI**, não inferido da descrição; as seis screenshots foram inspecionadas.
Achados completos em `ux-audit.json` (7 achados: 1 crítico + 6 avisos; 5 pontos fortes).

> **Como ler a nota.** A rubrica é aditiva: −15 por crítico, −7 por aviso, −3 por sugestão. 100 − 15 − (7×6) = **43**. O ofício visual é forte (contraste medido 6,0–14,3:1, um único trabalho por ecrã, háptica e notificação reais) e é isso que os pontos fortes registam. A banda `fair` vem de **defeitos semânticos da espinha dorsal** — a resposta pode ser cortada e ninguém a pode voltar a ler; o erro "Tentar de novo" não repete nada; não há como cancelar um pedido. Não é uma nota sobre estética.

---

## 1. As 5 correções prioritárias

### 1.1 Resposta truncada sem saída — `critical` · `D.1.1.01` progressive disclosure
`ContentView.swift:76-82` renderiza a resposta com `lineLimit(4)` + `minimumScaleFactor(0.72)` e não há scroll, "ver mais", sheet nem cópia. Num ecrã de 184 pt, quatro linhas de `footnote` levam ~90–110 caracteres: qualquer resposta maior é encolhida para ~9,4 pt e depois cortada com reticências (`lineLimit` trunca, não pagina). A única outra cópia é o corpo da notificação, ele próprio limitado a `lastReply.prefix(140)` em `AssistantController.swift:176`. A screenshot 04 cabe em quatro linhas, por isso o defeito é invisível em revisão de design — em produção é garantido para qualquer resposta com lista, resumo ou vários itens. E o CTA desse estado ("Novo comando") destrói a resposta imediatamente.

```swift
// ContentView.swift — manter a leitura de relance, mas dar saída ao texto completo
Text(controller.phase.headline)
    .font(.system(.subheadline, design: .rounded, weight: .semibold))
    .multilineTextAlignment(.leading)          // ver §4.2
    .lineLimit(controller.phase.isBusy ? 3 : 4)
    // .minimumScaleFactor(0.72)  <-- remover: ser honesto no corte
    .fixedSize(horizontal: false, vertical: true)
    .onTapGesture { showFullAnswer = true }    // ou Button("Ver tudo") numa 5.ª banda

.sheet(isPresented: $showFullAnswer) {
    ScrollView { Text(controller.lastReply).font(.body).padding() }
}
```

`lastReply` já persiste no controlador (`AssistantController.swift:12`) — só é limpo em `resetSession()`. Resultado mensurável: nenhuma resposta com reticências; texto completo em ≤2 toques.

### 1.2 "Tentar de novo" não tenta de novo — `warning` · `C.1.4.01` error prevention
Em `.failed`, `primaryAction()` chama `resetSession()` (`ContentView.swift:175-182`), que põe `phase = .idle`, limpa `activeTaskID` e apaga `lastReply`. `retryLastTask()` — o único método que voltaria a ligar-se à tarefa falhada — **não tem nenhum chamador na app**. Logo "Tentar de novo" é um "recomeçar do zero" silencioso: obriga a **ditar tudo outra vez**, o input mais caro num relógio. O ficheiro de áudio só sobrevive até ao próximo arranque (`VoiceRecorder.purgeOldRecordings(keepNewest: 1)`) e não há UI para o reenviar. O erro de emparelhamento é um ciclo fechado: "Emparelha o relógio com o Mac mini primeiro." → "Tentar de novo" → idle → toque → o mesmo erro (e `savePairingSecret` também não tem chamador).

```swift
private func primaryAction() {
    switch controller.phase {
    case .failed(let f) where f.isRetryable:   // erro de tarefa/rede: reenviar o que existe
        controller.resendLastAudio()            // re-upload do ficheiro retido
    case .failed:                               // erro que o utilizador tem de resolver
        showSessionDetails = true                // "Como emparelhar"
    default:
        controller.toggleRecording()
    }
}
```
Mapear `HubClient.Failure` para um `enum` com mensagens pt-PT tipadas e um passo seguinte, em vez de `error.localizedDescription` cru (que mistura idioma do sistema com copy portuguesa).

### 1.3 Não se pode cancelar um pedido — `warning` · `S.1.1.01` conversational flow
Com `phase.isBusy`, o orbe está `.disabled` (`ContentView.swift:60`), o botão está `.disabled` (`:137`) e `toggleRecording()` também não faz nada nesse estado (`AssistantController.swift:40-46`). Com `request.timeoutInterval = 120` e um modelo em "reasoning max", quem se enganou a falar fica a olhar para "A processar…" — a única saída é fechar a app à força. Um assistente conversacional num pulso tem de permitir barge-in.

```swift
private var actionButton: some View {
    Button(action: primaryAction) { ... }
        .disabled(false)                      // nunca bloquear a saída
}
// em primaryAction:
case .uploading, .waiting:
    controller.cancelActiveTask()             // cancelar pollingTask + resetSession()
```
Manter o anel de progresso como *estado*, não como *cadeado*. Resultado: comando indesejado abandonado com 1 toque; hub pendurado nunca prende o utilizador.

### 1.4 O utilizador nunca vê o que foi ouvido — `warning` · `S.1.3.01` AI transparency
`TaskStatus.transcript` é descodificado mas só serve de fallback dentro de `lastReply` (`AssistantController.swift:164`); nenhum estado o mostra. Num assistente de voz, a má transcrição é a falha nº 1 e aqui não há como detetá-la — nem antes nem depois do round trip. A proveniência também é opaca: destino do áudio, retenção e emparelhamento TOTP só existem no `SessionDetailsView`, que **não abre** (ver §2.1). O rodapé da resposta mostra backend + latência (bom), mas não diz em que máquina.

```swift
// .waiting — o hint genérico passa a provar o que foi ouvido
case .waiting:
    return controller.lastTranscript.map { "Ouvi: “\($0)”" }
        ?? "Podes baixar o pulso — aviso quando terminar"

// .answering — atribuir uma resposta estranha a má transcrição
if let t = controller.lastTranscript { Text("“\(t)”").font(.caption2).foregroundStyle(Palette.muted) }
```
E acrescentar o host do hub (`WPHubBaseURL`) ao rodapé `backend · latência`.

### 1.5 Tipo abaixo do mínimo da plataforma, sem Dynamic Type — `warning` · `F.1.1.02` cognitive load
O hint é `.system(size: 9.5)` fixo (`ContentView.swift:86`), o headline é `.footnote` com piso de 0,72 (≈9,4 pt), o CTA `.system(size: 13)` e as linhas da sessão 12/11. Nenhum usa text styles, portanto quem subiu o tamanho de texto do watchOS não recebe nada — e a resposta é o texto mais pequeno exatamente quando é o mais importante. A 9,5 pt o utilizador precisa de uma segunda olhadela, que é precisamente o que o pulso não permite.

```swift
Text(controller.phase.headline).font(.system(.subheadline, design: .rounded, weight: .semibold))
Text(footnote).font(.footnote)                       // remover size: 9.5
Text(primaryTitle).font(.headline)
// e no topo do ContentView:
.dynamicTypeSize(...DynamicTypeSize.accessibility1)  // bandas fixas continuam inteiras
```
Resultado: nenhum corpo de texto abaixo de 11 pt em qualquer tamanho, de xS a AX1.

---

## 2. Restantes avisos

### 2.1 A sheet de sessão é código morto — `warning` · `C.1.1.01` consistency
`@State private var showSessionDetails = false` existe, o `.sheet(isPresented:)` existe, e **nada na app põe o valor a `true`**: `SessionDetailsView` (URL do hub, origem do segredo, tarefa, "Terminar sessão") é inalcançável. Sobra o badge `exclamationmark.lock.fill` a 11 pt, só ícone, não interativo, sem ação — um aviso que o utilizador não consegue descodificar. Correção: embrulhar o overlay num `Button` 44×44 que abre a sheet e, com `!pairingReady`, trocar o hint genérico por "Não emparelhado — ver sessão".

### 2.2 Dois alvos concorrentes a 2 pt de distância — `warning` · `I.2.2.02` Fitts
`VStack(spacing: 2)` encosta um orbe de 84×78 pt a um botão full-width. Em idle/listening/answering fazem **a mesma coisa** (`toggleRecording()`); "Toca para falar" fica entre os dois sem dizer a quem se refere. Em `.failed` divergem pela primeira vez: o botão volta a idle, o orbe grava — 2 pt de erro mudam o comportamento. E o halo visível (raio ~48 pt num corpo de ~23 pt) sai fora do `contentShape(Rectangle())` de 84×78: parte do que brilha não é tocável. Correção: um só CTA primário; se o orbe ficar tocável, `.frame(width: 96, height: 96).contentShape(Circle())` e ≥16 pt de separação, e torná-lo inerte em `.failed`.

---

## 3. O que **não** vale a pena corrigir (app pessoal, um utilizador)

1. **Catálogo de strings / localização.** Toda a copy está inline em pt-PT. Um só utilizador, um idioma: um `.xcstrings` agora é custo sem retorno.
2. **Pedido de permissão de notificações dentro de `apply()`.** É pedido no primeiro sucesso (`AssistantController.swift:173`), o que é um timing estranho, mas defensável: garante contexto. Não vale interromper.
3. **`retryLastTask()` como código morto.** Apagar a função (1 linha) em vez de a integrar — desde que §1.2 fique resolvido pelo reenvio do áudio.
4. **Corte das barras de voz no estado listening.** É um defeito visível (na screenshot 02 só aparecem cotos nos quatro cantos: as barras radiais chegam a ~64 pt de raio num meio-frame de 42×39 pt e são cortadas; **quanto mais alto se fala, mais se corta**). Mas o pulso do orbe (`amplitude` até 0,52 com a potência) continua a dar feedback de nível, e há cor + texto + háptica `.start`/`.stop`. Correção barata para quando se mexer no orbe: `ringRadius = bodyRadius * 1.15` ou `.frame(width: 104, height: 104)`.
5. **Percentagem "62%" com precisão falsa.** `stepDescription` do hub não é linear no tempo; uma percentagem parada desgasta confiança. Mas o step text já informa. Só se mexer se o hub passar a reportar progresso fiável.
6. **Alinhamento centrado da resposta em 4 linhas e o `.padding(.horizontal, 2)`.** Ambos piores para releitura (arestas irregulares; linhas longas a ~7 pt do bisel, ver screenshot 06), mas um único utilizador aprende o layout em dois dias e o texto é curto. Trocar para `.leading` + `.safeAreaPadding` quando se tocar no bloco de texto por outro motivo.
7. **`TimelineView(.animation)` a 30 Hz sem variante para AOD / `isLuminanceReduced`.** `paused:` só depende de `accessibilityReduceMotion`. Custo real de bateria é pequeno para sessões de <10 s; vale revisitar se a app ganhar superfície always-on ou de longa duração.
8. **Microtipografia da `SessionDetailsView`** (monoespaçado 11 pt). Se a sheet só serve para diagnóstico, não vale polir.

---

## 4. Achados que considero **errados ou inaplicáveis** a este ecrã

1. **"Contraste insuficiente" — não se aplica.** Medi os pares reais sobre o fundo 0.020/0.031/0.047: mint **14,3:1**, vermelho **7,2:1**, muted **6,0:1**. Tudo ≥ AA; mint e vermelho passam AAA. Nenhum achado de contraste entra no JSON.
2. **"Alvos abaixo de 44 pt" — não se aplica.** Orbe 84×78 pt e CTA full-width com ≥44 pt de altura; e o CTA nunca é empurrado para fora do ecrã (`layoutPriority(1)` no bloco de texto, orbe e botão fixos).
3. **"Demasiados itens / Miller's law / Hick's law" — não se aplica.** Três bandas, uma decisão, zero navegação. O problema da app não é densidade, é semântica de ações.
4. **"Prevenção de erros em formulários" (`I.1.1.03`)** — não há formulário. Aplicá-lo seria inventar.
5. **A screenshot 06 (`live-hub`) não é copy de produção.** Aquele "Ligado ao hub · xiaomi/mimo-v2.6-pro · reasoning max · TOTP aceite" vem de `runLiveSmokeTest()`, dentro de `#if DEBUG` (`AssistantController.swift:225-239`). Seria um erro auditá-lo como jargão em produção; o achado legítimo é apenas que o headline renderiza `step_description`/`ai_reply` do servidor verbatim, com o mesmo tratamento de uma resposta humana — e isso fica registado em §1.4/§3.5, não como achado próprio.
6. **"A app promete um aviso e não cumpre"** — seria falso. O aviso existe mesmo: `postLocalNotification` + `play(.success)` no fim (`AssistantController.swift:169-178`), mais background refresh. Está nos pontos fortes.
7. **Progressive disclosure "clássica" (hambúrguer, navegação, multi-passo)** — inaplicável a um ecrã único de pulso; a violação real de `D.1.1.01` é só a resposta sem via para o texto completo.

---

## 5. Limitações desta auditoria

- `API enrichment = false`: sem chaves, sem `business_impact`, sem citações de princípios; a única fonte de enriquecimento foi o código e as seis screenshots.
- Não houve teste em hardware: os cortes das barras de voz e o aspeto do orbe foram lidos da renderização das screenshots (368×448 px) e da geometria em `AnimatedAssistantOrb.swift:23-147`.
- O tempo de "reasoning max" (que sustenta a severidade de §1.3) é inferido do timeout de 120 s em `HubClient.swift:75`, não medido.
