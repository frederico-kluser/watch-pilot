# docs/research — índice

Pesquisa profunda do watch-pilot (protocolo `tavily-agent-skill`, flag `--deep-research`). Cada ficheiro é um relatório de investigação; o dossiê consolida-os com fontes `[S#]` e níveis A–D.

| Ficheiro | Conclusão numa linha |
| --- | --- |
| [00-dossie-deep-research.md](00-dossie-deep-research.md) | Dossiê concluído: o hub faz transcrição e LLM, o relógio é cliente fino — 26 nós de FAQ, 50 fontes, lint `PRONTO-PARA-SINTESE`. |
| [Q1-speechanalyzer.md](Q1-speechanalyzer.md) | `SpeechAnalyzer`/`SpeechTranscriber` funcionam num binário CLI sem bundle nem TCC (~60× tempo real), mas não existem em watchOS. |
| [Q2-watchos-background.md](Q2-watchos-background.md) | O watchOS não tem execução contínua: pulso em baixo é suspensão, e a única janela de 1 h (`physical-therapy`) é purpose-bound. |
| [Q3-audio-capture.md](Q3-audio-capture.md) | `AVAudioRecorder` existe em watchOS 4.0+ e os settings (AAC 16 kHz mono 48 kbps) estão certos; 2 defeitos de sessão corrigidos. A gravação **não** sobrevive ao pulso em baixo sem o *Audio background mode*. |
| [Q4-apns-notifications.md](Q4-apns-notifications.md) | O Mac pode ser o provider APNs e o Watch recebe push directo, mas só com Apple Developer Program pago; a alternativa grátis é iMessage. |
| [Q5-openrouter-mimo.md](Q5-openrouter-mimo.md) | `xiaomi/mimo-v2.6-pro` é real e barato, mas `reasoning.effort` não chega ao provider: profundidade vem do prompt; DeepInfra é o melhor endpoint. |
| [Q6-totp.md](Q6-totp.md) | TOTP cabe em ~90 linhas de CryptoKit, sem dependências, com 44 vectores byte-idênticos entre Swift e Python. |
| [Q6b-cloudflare-publish.md](Q6b-cloudflare-publish.md) | Publicar em `watch.kluser.me` exige isenção do TOTP do runner e LaunchDaemon (TCC bloqueia `/Volumes` a qualquer job de launchd); a rota é reposta por watchdog. |
| [Q8-memoji-animoji.md](Q8-memoji-animoji.md) | Animoji/Memoji não têm API pública (AvatarKit é privado; o watchOS não tem ARKit nem RealityKit); a alternativa foi um personagem vectorial próprio com poses por estado. |

Nota: o nó Q3 ficou `inatingivel` no dossiê (§8) por ser um nó de *código*, não de pesquisa web; foi
fechado depois por revisão directa do SDK instalado + build — ver [Q3-audio-capture.md](Q3-audio-capture.md).
Continua por verificar em execução: teste no relógio físico, conta ADP real e áudio real de pulso.
