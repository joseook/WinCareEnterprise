# SECURITY-NOTES — WinCare Enterprise

> Registro da mb-sec-gate. Sem segredos, tokens ou dados pessoais neste arquivo.

| Campo | Valor |
|---|---|
| Nível de risco | **R2** — sem backend, contas ou dados de terceiros (seria R0/R1), mas é ferramenta local com potencial de rodar como administrador em parque corporativo e com cadeia de distribuição própria: comprometer o pacote atinge muitas máquinas. Subido um nível por precaução. O baseline sugeriu R3 por palavras-chave ("payments" no YAML de CI, "health" em textos de alerta) — falso positivo. |
| Escopo | Repositório público `joseook/WinCareEnterprise` (v0.2.0), site estático `wincare.joseok.cloud` (GitHub Pages, HTTPS forçado), releases no GitHub com manifesto assinado (RSA-3072). |
| Onde roda | Estação Windows do técnico/usuário (local). CI no GitHub Actions quando publicado. |
| Dados tratados | Inventário técnico da própria máquina (edição, hardware, processos, comandos de inicialização, nome do computador/domínio). Fica local (`%LOCALAPPDATA%\WinCare`). Nada é enviado a terceiros. Relatórios podem conter nome de máquina/domínio/usuário em itens de inicialização — tratar como dado interno da organização. |
| Responsável | Mantenedor do projeto · contato de incidente: GitHub Security Advisories do repositório |
| Última revisão | 2026-11-16 (2ª: release v0.2.0, `irm \| iex`, elevação) · próxima: em 180 dias, ao trocar a chave, ou ao adicionar ação de risco alto |

## Diagrama de fluxo de dados
```mermaid
flowchart LR
  T([Técnico]) -->|irm /run \| iex ou comando verificado| S[run.ps1 / one-liner: confere SHA-256 do install.ps1]
  S --> B[install.ps1 com chave RSA fixada]
  subgraph F1[Fronteira: internet / mídia ↔ máquina]
    P[(GitHub Pages wincare.joseok.cloud)] -->|HTTPS run + install.ps1| S
    GH[(GitHub Releases)] -->|HTTPS zip + manifesto + .sig| B
    USB[(Mídia offline)] -->|zip + manifesto + .sig| B
  end
  B -->|verifica RSA do manifesto + SHA-256 do zip e de cada arquivo| C[(Cache: usuário %LOCALAPPDATA% / admin Program Files)]
  A -.->|Executar como administrador: -EncodedCommand, baixa install.ps1 p/ Program Files e confere hash| B
  C --> A[WinCare UI / -NoGui]
  subgraph F2[Fronteira: usuário ↔ sistema]
    A -->|CIM/registro somente leitura| W[(Windows)]
  end
  A --> L[(Logs JSONL + relatórios)]
  subgraph F3[Fronteira: CI ↔ release]
    K[(Chave privada RSA: só na máquina do mantenedor)] -->|assina manifesto| GH
    CI[GitHub Actions: só testes, sem segredos] -.-> T2([status])
  end
```

## Ameaças (registro)
| ID | Ameaça | Ativo | P | I | Nota | Tratamento | Controle / evidência | Dono | Status |
|---|---|---|---|---|---|---|---|---|---|
| T1 | Pacote adulterado (servidor, MITM, mídia) executa código como admin | Máquinas do parque | 3 | 5 | 15 | Mitigar | Manifesto assinado RSA-3072 com chave fixada no `install.ps1`, hash do zip e de cada arquivo, rejeição de arquivo extra; Authenticode opcional; `tests/Bootstrap.Tests.ps1` + teste RSA real no Windows (CI) | Mantenedor | Mitigado (validado no CI Windows) |
| T2 | Zip com caminho malicioso (zip slip) grava fora da pasta | Máquina | 2 | 4 | 8 | Mitigar | `Expand-WcbZipSafe` + 5 casos de teste | Mantenedor | Mitigado |
| T3 | Usuário contorna política com `iex`/`Bypass` copiados de tutorial | Política corporativa | 3 | 4 | 12 | Evitar | Sem `iex`/Bypass no código (teste AST); docs explicam o porquê | Mantenedor | Mitigado |
| T4 | Ação futura desativa proteção (Defender, Firewall…) | Postura de segurança | 2 | 5 | 10 | Evitar | Recursos protegidos rejeitados no carregamento do catálogo; teste | Mantenedor | Mitigado |
| T5 | XSS no relatório HTML via nome de processo/rótulo | Quem abre o relatório | 3 | 3 | 9 | Mitigar | HtmlEncode em todo valor + CSP `default-src 'none'`; teste | Mantenedor | Mitigado |
| T6 | Cache adulterado após verificação (outro processo do usuário) | Máquina | 2 | 4 | 8 | Mitigar | Reverificação a cada execução | Mantenedor | Mitigado (mocks) |
| T7 | Chave de assinatura vazada → pacote malicioso "válido" | Todo o parque | 2 | 5 | 10 | Mitigar/aceitar | Chave só na máquina do mantenedor (`~/.config/wincare-signing`, permissão 600), nunca no CI nem no repositório; troca = nova chave fixada em novo `install.ps1` + novo hash no README/site. Sem HSM (custo) | Mantenedor | **Exceção (ver abaixo)** |
| T8 | Ação de CI comprometida (supply chain) | Release | 2 | 4 | 8 | Mitigar | Actions fixadas por SHA, `permissions: contents: read`, CI sem segredos, assinatura fora do CI | Mantenedor | Mitigado |
| T10 | `irm \| iex`: site ou conta GitHub comprometidos servem `run` malicioso | Máquinas que usarem o atalho | 2 | 5 | 10 | Mitigar/avisar | `run` só baixa `install.ps1` e confere hash; comando verificado com hash no README (canal independente); 2FA na conta; docs avisam o risco e o alerta de EDR | Mantenedor | Aceito com aviso |
| T11 | Escalada de privilégio: processo elevado executa arquivo gravável pelo usuário | Máquina | 2 | 5 | 10 | Mitigar | Admin usa cache em Program Files; elevação por `-EncodedCommand` validado (versão/hash/URL com lista de caracteres) que baixa `install.ps1` para Program Files e confere hash do pacote assinado; testes de injeção | Mantenedor | Mitigado (testes); UAC real pendente |
| T12 | Política corporativa contornada | Conformidade | 1 | 4 | 4 | Evitar | Nunca `Bypass`/`Set-ExecutionPolicy`; GPO `Restricted`/`AllSigned` e modo de linguagem restrito detectados e explicados; caminho legítimo = reassinatura pela PKI da organização (teste `AllSigned` real no CI) | Mantenedor | Mitigado |
| T9 | Relatório com dados internos compartilhado indevidamente | Info da organização | 3 | 2 | 6 | Aceitar/avisar | Relatórios ficam locais; aviso na página de relatórios | Mantenedor | Aceito |

## Baseline
`sec_baseline.py` em 2026-11-16: **0 BLOCKER · 0 AVISO · 1 INFO** (sem manifesto de dependências — esperado: projeto sem dependências de runtime).

## Plano de segurança
| # | Skill | Escopo | Bloqueia? | Status | Resultado |
|---|---|---|---|---|---|
| 1 | mb-appsec | Scripts PowerShell, bootstrapper, cadeia de suprimentos | Antes do 1º release | Feito inline | Injeção no comando elevado encontrada e corrigida (URL com aspas); AST proíbe `iex`/Bypass; zip slip testado |
| 2 | mb-infra-security | GitHub Actions, assinatura, publicação, DNS | Antes do 1º release | Feito inline | Actions por SHA, permissões mínimas, Pages com HTTPS forçado (cert até 2027-02-14), CNAME `wincare` só para `joseook.github.io` |
| — | mb-api-security, mb-data-protection, mb-ai-security, mb-phishing-defense | Não se aplicam (sem API, sem dado pessoal enviado, sem IA, sem domínio de e-mail) | — | N/A | — |

## Gate de liberação
Decisão: **LIBERADO COM RESSALVAS para o release v0.2.0** (publicação autorizada pelo usuário em 2026-11-16). Ressalvas: exceção T7 abaixo; homologação em Windows cliente pendente (o release é marcado como pré-lançamento).

## Exceções aceitas
| Item | Motivo | Controle compensatório | Dono | Expira em |
|---|---|---|---|---|
| Kit de validação sem assinatura | É kit de laboratório, não release | Só VM/laboratório; SHA-256 por canal separado; bootstrapper rejeita o kit | Mantenedor | — |
| T7: chave RSA sem HSM | Custo; projeto pessoal open source | Chave fora do repo/CI, permissão 600, troca documentada; Authenticode opcional pela PKI da organização | Mantenedor — aceito por escrito pelo usuário em 2026-11-16 | 2027-05-16 |

## Histórico
- 2026-11-16: gate inicial (F1/F2).
- 2026-11-16: revisão para v0.2.0 — modelo RSA, `irm | iex`, elevação, PKI da organização; T8 mitigado; T10–T12 adicionados.
