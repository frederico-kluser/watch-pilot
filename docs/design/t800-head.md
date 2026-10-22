# A cabeça do T-800 — geometria, animação e contrato de integração

Este documento fecha a parte de **design** da cabeça. A funcionalidade (áudio do
relógio, TTS do hub, medidor de nível) fica para quem a construir; aqui está tudo o
que essa pessoa precisa para ligar o áudio à cara sem tocar no desenho.

## 1. O que está feito

| Peça | Onde | O que é |
| --- | --- | --- |
| Geometria | `apps/watch/WatchPilot/UI/T800HeadArt.swift` | 17 camadas de metal (crânio + mandíbula) + o contorno da cabeça, em *unit space*, geradas a partir da referência |
| Desenho | `apps/watch/WatchPilot/UI/T800Head.swift` | `T800Head.draw(in:center:unit:pose:time:)` — pinta as camadas, os olhos e a boca; função pura |
| Ligação ao estado | `apps/watch/WatchPilot/UI/AssistantAvatar.swift` | `AvatarPose` → `HeadPose`; o renderer não tem `switch` de estados |
| Fonte da verdade | `docs/design/reference/t800-visor.jpg` | o mockup de onde tudo foi medido |
| Gerador | `scripts/design/trace-head.py` | re-traça a referência e reescreve o `T800HeadArt.swift` |
| Movimento | `docs/design/t800-head.gif` | gravação real do simulador a falar |

Não há imagens no bundle: tudo são `Path`s gerados + gradientes. A cabeça escala
por **um número** (`unit`, em pontos) e não muda uma única vértice entre tamanhos
de relógio.

## 2. Como a referência foi medida (técnica de grelha)

O crânio foi isolado do mockup e medido contra a grelha do ecrã do relógio
(796×951 px de vidro):

| Grandeza | Pixels | Fracção do ecrã | No código |
| --- | --- | --- | --- |
| centro do crânio | (1370, 729) | (0,500 · 0,433) | `skullCenter = (w/2, 0.433h)` |
| meia-altura (cúpula→queixo) | 244 | 0,307 da largura | `unit = 0.3066w` |
| largura do crânio | 307 | 0,386 da largura | arte: ±0,63 unidades |
| raio do anel | 239 | 0,300 da largura | `ringRadius = 0.300w` |
| pupila (disco vermelho) | r 18,6 | 0,076 unidades | `T800HeadArt.pupilL/R` |
| núcleo da pupila | r 10,9 | 0,0447 unidades | idem |
| olho esquerdo / direito | (1297,8 ; 715,8) / (1442,4 ; 715,7) | ±0,296 unidades | idem |
| pontos da órbita | 6 discos r≈4,7 | ±0,0193 unidades | `dotsL/dotsR` |
| linha da boca | y = 880,5 | 0,62 unidades | `mouthCavity` |
| abertura máxima da mandíbula | — | 0,042 unidades | `jawDropMax` |

O `script` de trace usa a mesma tabela; mudar a referência e re-correr o gerador
mantém tudo coerente.

## 3. Como está construída a arte

* **Tons planos**: 10 degraus de metal (`palette`) amostrados do mockup — dois meios-tons
  (esquerda iluminada / direita em sombra) e as placas escuras.
* **Tesselação**: cada tom é uma `Path` fechada, preenchida com `FillStyle(eoFill:)`
  (os buracos vêm do potrace). Como as formas não se sobrepõem, a ordem não altera
  o resultado; o contorno é fechado com um traço de 0,0035 unidades da própria cor.
* **Dois grupos**: `jaw == false` (crânio, órbitas, dentes de cima) e `jaw == true`
  (dentes de baixo, maxilar inferior, painéis do queixo). O grupo da mandíbula
  desloca-se em `y` para a boca abrir; atrás dela é pintada a **cavidade preta**,
  para a abertura nunca mostrar o fundo.
* **Olhos procedurais**: as pupilas são desenhadas (halo + anel + núcleo) e não
  traçadas, para poderem brilhar, dilatar, olhar para o lado e falhar.

## 4. Contrato de animação (o que o implementador tem de alimentar)

`AvatarPose` é a única superfície. Para a cabeça contam estes campos:

| Campo | Tipo | Efeito no T-800 |
| --- | --- | --- |
| `speechLevel` | `0…1`, `-1` = sintético | **abre a mandíbula e acena com a cabeça**; é o gancho do áudio real |
| `jawOpen` | `0…1` | abertura base (a falha deixa a mandíbula pendurada: 0,16) |
| `eyeGlow` | `0…1` | halo vermelho + brilho da pupila |
| `eyeScale` | ~0,9…1,2 | dilatação (a ouvir = 1,12) |
| `eyeLook` | `CGSize`, pontos | para onde olha (convertido para unidades no renderer) |
| `eyeFlicker` | `Bool` | olho direito a falhar (estado de erro) |
| `headYaw` | `−1…1` | vira a cabeça: aperto de 12 % + paralaxe das peças |
| `headTilt` / `headScale` | rad / ~1 | inclinação e aproximação |
| `chrome` | `0…1` | brilho do metal (falha = 0,72) |
| `hudGlitch` | `Bool` | rasga a cabeça em 12 fatias deslocadas |

### Ligar o áudio da resposta (o passo que falta)

1. O T-800 toca a resposta: o relógio mede o nível da reprodução (0…1, ~30 Hz).
2. Escreve-se esse valor em `controller.speechLevel` (novo `private(set) var`).
3. `ContentView` passa-o para a pose: `AvatarPose(..., speechLevel: controller.speechLevel)`.
4. `speechLevel >= 0` desliga a cadência sintética e a boca passa a seguir o áudio —
   a mandíbula, o aceno e a dilatação das pupilas ficam em sincronia com a voz.

Enquanto o hub devolver **texto**, `speechLevel` fica em `-1` e a boca usa
`speechEnvelope(time)` (`AssistantAvatar.swift`), uma cadência de sílabas
deliberadamente irregular para não parecer um loop.

### Alimentar o"a ouvir"

`AssistantPhase.listening(power:)` já traz a potência do microfone; `forPhase` mapeia-a
para `eyeScale`, `eyeGlow`, `headYaw` e para a waveform. Não é preciso mais nada.

## 5. Movimento: o que se mexem e com que período

| Gesto | Fórmula | Estado |
| --- | --- | --- |
| varredura da cabeça | `headYaw = 0.55·sin(0,45t)` | `idle`, `waiting` |
| aceno de fala | `nod = sin(1,7t)·0,35 + fala·sin(7,3t)·0,9` | todos |
| cadência da boca | sílabas `max(0,sin(7,3t))` moduladas por `sin(1,31t)` | `answering` |
| dilatação | `eyeScale` da pose + 5 % durante a fala | `listening`, `answering` |
| halo | opacidade `0,20·eyeGlow` | todos |
| falha | `tear = 0,35 + 0,25·sin(5,1t)`, fatias de `hash(n, t)` | `failed` |

Períodos não múltiplos entre si: o conjunto nunca repete visivelmente. Com
**Reduce Motion** o `TimelineView` pára e a pose continua legível — cor, dilatação e
abertura da boca carregam a informação.

## 6. Regenerar a arte

```bash
python3 -m pip install numpy opencv-python-headless potracer
python3 scripts/design/trace-head.py          # reescreve T800HeadArt.swift (~50 s)
cd apps/watch && xcodegen generate --spec project.yml
python3 ~/Agent-Skills/watch-pilot-animation-agent-skill/scripts/anim-doctor.py --build
```

O gerador imprime quantas camadas traçou e quantos bytes tem a arte. Se mudares a
referência, compara o resultado com `docs/design/reference/t800-visor.jpg` antes de
fechar: a métrica usada foi **MAE 5,2** dentro do crânio (1,4 % de pixels com
diferença > 45), medida a 1 unidade = 244 px com a pose neutra.

## 7. Limites conhecidos

* A transição entre poses é instantânea (o renderer é puro). Suavizar exige um
  interpolador na view, não dentro do desenho.
* A mandíbula desloca-se em `y`; não roda em torno de um eixo. A leitura é
  mecânica e suficiente ao tamanho do relógio.
* O GIF e as capturas vieram do simulador (SE 44 mm); falta confirmar no relógio
  físico, sobretudo o custo de 17 `Path`s a 30 Hz.
