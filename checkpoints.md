# Checkpoints — wincare-enterprise

## 2026-11-16 — linux (Zorin OS)
- Feito: F1 (estrutura modular, WPF com 11 páginas, tema/idioma, console, execução assíncrona, bootstrapper seguro) e F2 (diagnóstico real somente leitura + alertas + relatórios). Motor de políticas, perfis, catálogo e dry-run. 231 testes Pester verdes no pwsh 7.7 (Linux); 11 testes Windows pendentes. Kit de validação `dist/WinCare-Validation-0.1.0.zip`. Gate de segurança: SECURITY-NOTES.md (R2; liberado para laboratório, bloqueado para release).
- Pendente: rodar o kit em VM Windows 10 e 11 (usuário padrão + admin) e anexar relatórios; corrigir o que aparecer; F3 (limpeza controlada, SFC/DISM/chkdsk com confirmação).
- Próximo passo: validação no Windows real (docs/VALIDACAO-WINDOWS.md).
- Commit: ver git log

## 2026-11-16 (2) — linux (Zorin OS)
- **Feito:**
  - F3 e F4 (sessão anterior); F5 (antes/depois, ponto de restauração, campo Reversibility).
  - Repo público e CI Windows real (PS 5.1).
  - Site `wincare.joseok.cloud` (Pages + HTTPS).
  - `irm | iex` (`/run`) e comando verificado.
  - Elevação segura e detecção de GPO/AppLocker.
  - Reassinatura pela PKI da organização, com teste real de `AllSigned` no CI.
  - Actions fixadas por SHA e SECURITY-NOTES revisado.
- **Pendente:** homologação em Windows 10/11 cliente; aceite escrito da exceção T7; integração da F5 na interface (diálogo de confirmação com status do ponto de restauração e grade de pontos existentes).
- **Próximo passo:** checklist `docs/VALIDACAO-WINDOWS.md` em máquina cliente.
- **Commit:** ver `git log` (main).

## 2026-11-16 (3) — linux (Zorin OS)
- **Feito:**
  - v0.2.1 homologada pelo usuário (Windows 11 corporativo).
  - Tabelas redesenhadas.
  - Três módulos novos, feitos por agentes em paralelo: Processos, Saúde, Apps+Rede.
  - Quatro páginas de análise; seleção de linha para ações (encerrar processo, winget, Store).
- **Bugs do Windows real corrigidos:**
  - O módulo Storage do Windows transforma MediaType em texto.
  - `Sort-Object` não é estável no 5.1.
  - Mocks de cmdlets CDXML.
- **Release:** v0.3.0 publicado.
- **Pendente:** validar em Windows cliente as ações novas (winget upgrade, Store reset, renovar IP, Winsock, encerrar processo, relatórios do powercfg).
- **Commit:** ver `git log` (main).

## 2026-11-25 — linux (Zorin OS)
- **Feito:** correção relatada pelo usuário: com o PowerShell já elevado, as ações seguiam com a etiqueta "requer administrador". A detecção de admin estava certa (ações liberadas, botão de elevar oculto); a etiqueta era fixa. Agora `Get-WcActionAdminTagKey` (Core, testada) mostra "administrador ativo" quando elevado. Release **v0.3.2** publicado (GitHub Release + gh-pages), CI verde em PS 5.1, PS 7 e Linux; `/run` e `install.ps1` servidos com hash `38DEA8DD…3025D44`; `install.ps1 -VerifyOnly` ponta a ponta OK.
- **Pendente:** homologação em Windows 10/11 cliente (sem mudança).
- **Próximo passo:** usuário roda `irm https://wincare.joseok.cloud/run | iex` como admin e confirma "administrador ativo".
- **Commit:** fbc781c (fix), 96f41be (release).

## 2026-11-25 (2) — linux (Zorin OS)
- **Feito:** a pedido do usuário ("não deveria vir bloqueado"), v0.3.3: perfil padrão = Avançado (migração de settings v1 "Diagnostico"); em dispositivo gerenciado, ações sensíveis mostram aviso em vez de bloquear (Corporativo/Diagnóstico mantêm bloqueio). Decisão em SECURITY-NOTES. CI verde (5.1, 7, Linux), release e site publicados, `-VerifyOnly` ponta a ponta OK.
- **Pendente:** homologação em Windows cliente.
- **Próximo passo:** usuário roda `/run` como admin e confirma ações liberadas.
- **Commit:** 2ffc1f2 (feat), da78a39 (release).
