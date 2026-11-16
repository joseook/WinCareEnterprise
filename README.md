# WinCare Enterprise

Ferramenta open source de diagnóstico e manutenção do Windows para técnicos e ambientes corporativos. PowerShell-first, interface WPF, sem instalador, sem `irm | iex`.

> **Estado: v0.1.0 — Fases F1 (fundação) e F2 (diagnóstico).**
> Desenvolvido e testado em Linux (pwsh 7.7 + Pester 5). **Nenhuma funcionalidade está homologada**: só será considerada validada depois de executada no Windows real com o kit de validação (`docs/VALIDACAO-WINDOWS.md`). Matriz em `docs/COMPATIBILIDADE.md`.

## O que já existe

| Área | Situação |
|---|---|
| Interface WPF: menu lateral, 11 páginas, tema escuro/claro, pt-BR/en-US, console de logs | Implementado, **não validado no Windows** |
| Diagnóstico real (somente leitura): Windows/edição/build, CPU (amostrado), RAM, discos + HDD/SSD, tempo ligado, reinicialização pendente, processos, inicialização, sinais de gerenciamento, Defender/Firewall | Implementado, lógica testada no Linux com mocks |
| Alertas com limiar documentado (sem "nota de saúde") | Implementado e testado |
| Execução assíncrona (runspace) + cancelamento | Implementado, **não validado no Windows** |
| Motor de políticas: 4 perfis, catálogo de ações (lista permitida), recursos protegidos, dry-run, confirmação, auditoria | Implementado e testado |
| Relatórios JSON/HTML + log de auditoria JSONL | Implementado e testado |
| Bootstrapper com SHA-256 + Authenticode + catálogo assinado, cache versionado, modo offline | Implementado, testado com mocks; **sem certificado e sem release publicado** |
| Otimização, Office, Integridade (execução), rollback | Planejado (F3–F5); páginas informativas, sem botões falsos |

## Começar

**Validar no Windows (laboratório/VM):** gere o kit e siga `docs/VALIDACAO-WINDOWS.md`.

```bash
pwsh -File scripts/New-ValidationPackage.ps1   # dist/WinCare-Validation-<versão>.zip + .sha256
```

**Executar a partir do código (Windows):**

```powershell
powershell.exe -NoProfile -STA -File .\src\Start-WinCare.ps1          # interface
powershell.exe -NoProfile -File .\src\Start-WinCare.ps1 -NoGui -OutputPath .\diag.html   # sem interface
```

**Release assinado (depois da F6):** um comando, sem `iex`, verificado antes de executar:

```powershell
powershell.exe -NoProfile -File .\Install-WinCare.ps1 -Version 0.1.0
```

Detalhes em `docs/EXECUCAO.md` e `docs/OFFLINE.md`.

## Testes

```bash
pwsh -File scripts/Invoke-WinCareTests.ps1    # Linux: exclui a tag Windows automaticamente
```

No Windows o mesmo script roda também os testes de integração reais (`tests/Windows`).

## Estrutura

```
bootstrap/Install-WinCare.ps1   inicializador seguro (autocontido)
src/Start-WinCare.ps1           ponto de entrada (GUI ou -NoGui)
src/WinCare.psd1                manifesto (versão única do app)
src/Core/                       núcleo portátil: log, idioma, config, perfis, catálogo, políticas, dry-run
src/Modules/                    coleta (System, Storage, Startup, Security), Diagnostics, Reporting
src/UI/                         WPF: MainWindow, Pages/, Themes/, WinCare.UI.psm1 (só Windows)
src/Localization/               pt-BR.json, en-US.json
tests/                          Pester 5 (portáveis) + tests/Windows (integração real + kit)
scripts/                        testes, kit de validação, release assinado
docs/                           execução, offline, arquitetura, metodologia, compatibilidade, limitações
```

## Segurança

Leia `SECURITY.md`. Em resumo: abrir o WinCare não altera nada; nenhum perfil desativa Defender, Firewall, BitLocker, Windows Update, GPO, MDM, EDR, VPN ou autenticação; a política de execução nunca é contornada.

## Licença

MIT — veja `LICENSE`. Arquitetura própria; inspirado na facilidade de uso de ferramentas da comunidade, sem copiar código, interface ou identidade visual.
