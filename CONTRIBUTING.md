# Contribuindo

1. **Windows PowerShell 5.1** é o alvo: nada de `?:`, `??`, `?.`, `ForEach-Object -Parallel`, `ConvertFrom-Json -AsHashtable`, `Join-Path` com 3+ partes.
2. **Scripts só em ASCII.** Texto com acento vai para `src/Localization/*.json` (mesmas chaves em pt-BR e en-US).
3. **Coleta = `Get-*` (I/O) + `ConvertTo-*` (puro).** Todo conversor novo ganha teste com fixture; todo `Get-*` novo ganha teste com mock e um teste real em `tests/Windows` (tag `Windows`).
4. **Ação nova que modifica o sistema:** entrada no `actions.json` (risco, reversível, admin, `BlockedWhenManaged`, `MinBuild`/`Editions`) + handler com `Preview` sem efeitos + testes de dry-run e confirmação + validação em VM antes de habilitar.
5. **XAML:** sem `x:Class`, sem eventos inline, só `DynamicResource`; textos via `str.<chave>`.
6. **Antes de commitar:** `pwsh -File scripts/Invoke-WinCareTests.ps1` verde.
7. **Commits** pequenos e objetivos, sem `Co-Authored-By`/`Generated with`.
8. Nenhuma funcionalidade é "homologada" sem relatório do kit em Windows real (`docs/VALIDACAO-WINDOWS.md`).
