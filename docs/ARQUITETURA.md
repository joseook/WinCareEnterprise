# Arquitetura

## Camadas

| Camada | Arquivos | Roda no Linux? | Testes |
|---|---|---|---|
| Núcleo | `src/Core/WinCare.Core.psm1`, `actions.json` | Sim | `tests/Core.Tests.ps1` |
| Coleta | `src/Modules/WinCare.{System,Storage,Startup,Security}.psm1` | Conversores sim; chamadas CIM/registro só no Windows | `Collectors.Tests.ps1` (fixtures + mocks), `tests/Windows` (real) |
| Diagnóstico e relatórios | `WinCare.Diagnostics.psm1`, `WinCare.Reporting.psm1` | Sim | `Diagnostics.Tests.ps1`, `Reporting.Tests.ps1` |
| Interface | `src/UI/*` | Não (WPF) | `Static.Tests.ps1` (XAML estático), `tests/Windows` (XamlReader real), checklist manual |
| Inicializador | `bootstrap/Install-WinCare.ps1` | Lógica sim; Authenticode só no Windows | `Bootstrap.Tests.ps1` (mocks), `tests/Windows` (real) |

Padrão em toda coleta: `Get-*` (fino, faz I/O, mockado nos testes) + `ConvertTo-*` (puro, transforma dados, testado com fixtures).

## Motor de políticas
- **Catálogo** (`actions.json`) = lista permitida. Só traz metadados: id, categoria, risco, modifica?, requer admin?, reversível?, bloqueado se gerenciado, build mínimo, edições, handler. Nunca traz código.
- **Handlers** são registrados no código (`Register-WcActionHandler`) com `Preview` (sem efeito) e `Execute`.
- Ação que declara tocar em recurso protegido (Defender, Firewall, BitLocker, Windows Update, GPO, MDM, EDR, VPN, autenticação, inventário, política de execução, UAC, SmartScreen) **é rejeitada ao carregar o catálogo** — nenhum perfil consegue liberá-la.
- **Perfis**: Diagnóstico (somente leitura), Conservador (risco baixo), Corporativo (risco baixo + bloqueia ações sensíveis a políticas mesmo sem detectar gerenciamento), Avançado (até risco alto, confirmação individual).
- **Plano**: `New-WcPlan` avalia cada ação → `Invoke-WcPlan` executa. `-DryRun` chama só `Preview`. Ação que modifica só executa com confirmação explícita. Tudo vai para o log de auditoria.

## Threading da interface
- A thread do WPF nunca executa diagnóstico.
- `Start-WcUiJob` cria um runspace com o manifesto importado e roda com `BeginInvoke`.
- Um `DispatcherTimer` (200 ms) verifica conclusão e esvazia a fila de log (`ConcurrentQueue`) — toda atualização de tela acontece na thread da UI.
- Cancelar chama `PowerShell.BeginStop()`.

## Compatibilidade 5.1 garantida por teste
- Parser do PowerShell em todos os scripts.
- Somente ASCII em `.ps1/.psm1/.psd1` (o 5.1 lê UTF-8 sem BOM como ANSI); textos com acento ficam nos JSON de idioma.
- PSScriptAnalyzer: `PSUseCompatibleSyntax` (5.1), `PSUseCompatibleCommands` e `PSUseCompatibleTypes` com o perfil Windows 10 1809 / PS 5.1.
- XAML sem `x:Class` e sem eventos inline (requisito do `XamlReader`).
