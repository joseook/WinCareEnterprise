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
