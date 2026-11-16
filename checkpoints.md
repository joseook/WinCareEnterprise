# Checkpoints — wincare-enterprise

## 2026-11-16 — linux (Zorin OS)
- Feito: F1 (estrutura modular, WPF com 11 páginas, tema/idioma, console, execução assíncrona, bootstrapper seguro) e F2 (diagnóstico real somente leitura + alertas + relatórios). Motor de políticas, perfis, catálogo e dry-run. 231 testes Pester verdes no pwsh 7.7 (Linux); 11 testes Windows pendentes. Kit de validação `dist/WinCare-Validation-0.1.0.zip`. Gate de segurança: SECURITY-NOTES.md (R2; liberado para laboratório, bloqueado para release).
- Pendente: rodar o kit em VM Windows 10 e 11 (usuário padrão + admin) e anexar relatórios; corrigir o que aparecer; F3 (limpeza controlada, SFC/DISM/chkdsk com confirmação).
- Próximo passo: validação no Windows real (docs/VALIDACAO-WINDOWS.md).
- Commit: ver git log
