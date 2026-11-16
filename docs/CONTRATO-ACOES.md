# Contrato de ações (F3+)

Toda ação que o WinCare executa segue este contrato. A UI (páginas Otimização rápida/avançada, Integridade, Office) é genérica e lê o catálogo.

## 1. Catálogo — `src/Core/actions.d/<modulo>.json`
```json
{ "actions": [ {
  "Id": "cleanup.user-temp", "Category": "Storage", "Risk": "Low",
  "Modifies": true, "RequiresAdmin": false, "Reversible": false, "Reversibility": "None",
  "RequiresWindows": true, "BlockedWhenManaged": false,
  "MinBuild": 10240, "Editions": null,
  "Pages": ["quick", "advanced"],
  "Handler": "Cleanup-UserTemp",
  "TitleKey": "action.cleanup.user-temp", "DescriptionKey": "action.cleanup.user-temp.desc"
} ] }
```
- `Risk`: None (só leitura) | Low | Medium | High. Modifica ⇒ nunca None.
- `Reversible:false` ⇒ a UI mostra "irreversível" e exige confirmação.
- `Reversibility` (obrigatório, F5) — como desfazer, de forma honesta:
  - `ReadOnly`: não modifica (exigido quando `Modifies:false`);
  - `None`: modifica e **não** pode ser desfeito pelo WinCare (exige `Reversible:false`);
  - `RestorePoint`: mudança de estado do sistema que um ponto de restauração tirado antes desfaz (exige risco Medium/High).
  Valores atuais: limpeza de temporários, ReTrim, `sfc /scannow` e `DISM /RestoreHealth` = `None`; todo o resto = `ReadOnly`. Nenhuma ação atual declara `RestorePoint`.
- `Touches` com recurso protegido (Defender, Firewall, BitLocker, WindowsUpdate, GroupPolicy, MDM, EDR, VPN, Authentication, Inventory, ExecutionPolicy, UAC, SmartScreen) ⇒ catálogo rejeitado.
- `Pages`: quick | advanced | integrity | office | storage | startup.

## 2. Handler — função `Register-Wc<Modulo>Handler` exportada (registro preguiçoso)
```powershell
function Register-WcCleanupHandler {
    Register-WcActionHandler -Name 'Cleanup-UserTemp' -Preview { param($Context) ... } -Execute { param($Context) ... }
}
Export-ModuleMember -Function @('Register-WcCleanupHandler', ...)
```
- **Não** registrar na importação: carregado pelo `WinCare.psd1` (NestedModules), o módulo ainda não enxerga as funções do Core (achado no CI Windows). `New-WcPlan` chama `Initialize-WcActionHandlers`, que executa todas as `Register-Wc*Handler`.
- O módulo novo entra em `NestedModules` do `WinCare.psd1`; o teste de sessão limpa (`Static.Tests.ps1`) falha se alguma ação do catálogo ficar sem handler.
- **Preview** não altera nada. Retorna `New-WcActionResult` com o que *seria* feito (itens, bytes estimados).
- **Execute** faz a ação e retorna `New-WcActionResult` com antes/depois medidos.
- Formato (`[pscustomobject]`): `Summary` (string curta, inglês técnico; a UI mostra), `Items` (array de objetos simples para tabela), `BytesBefore`/`BytesAfter`/`BytesFreed` (quando couber), `Output` (texto bruto de comando externo), `ExitCode`, `RollbackData` (`$null` se irreversível — nenhuma ação atual tem desfazer próprio).
- **Measure** (opcional, F5): `-Measure { param($Context) ... }` no `Register-WcActionHandler`. Somente leitura, rápido, devolve métricas `New-WcMetric -Name -Target -Unit -Value` (ou hashtables com essas chaves). Roda antes e depois do Execute. Ex.: limpeza de temporários mede `FolderBytes` e `FileCount` da pasta-alvo.
- Comandos externos: só por caminho absoluto em `$env:SystemRoot\System32`, argumentos fixos em array (nada vindo de texto livre), saída capturada, `ExitCode` registrado. Progresso via `Write-WcLog` (aparece no console da UI).
- Erros: `throw` com mensagem clara; o plano marca `Failed` e segue.

## 3. Idioma — `src/Localization/pt-BR.d/<modulo>.json` e `en-US.d/<modulo>.json`
Mesmas chaves nos dois. Chave duplicada entre arquivos = erro na carga.

## 4. Testes — `tests/<Modulo>.Tests.ps1`
- Conversores puros com fixtures; I/O com `Mock -ModuleName`.
- Para cada ação que modifica: Preview não chama nada destrutivo (mock de `Remove-Item`/comando com `-Times 0`); Execute só remove o que o Preview listou; caminhos fora da lista permitida são recusados.
- Só ASCII nos `.ps1/.psm1`; sintaxe 5.1.

## 5. Antes/depois e ponto de restauração (F5)
`Invoke-WcPlan` (sem `-DryRun`) faz, para cada item executado:
1. **Ponto de restauração**, uma vez por plano, antes do primeiro item confirmado que precise (`Test-WcRestorePointRequired`): `Modifies` e (`Risk:High` ou `Reversibility:RestorePoint`; com `-RestorePointPolicy MediumAndHigh` também `Medium`; `Off` desliga). Padrão: `High`.
2. Medição **antes** = gancho genérico (`FreeBytes` por unidade fixa, CIM `Win32_LogicalDisk DriveType=3`) + `Measure` do handler.
3. Execute; medição **depois** (também se o Execute falhar).
4. `Comparison = ConvertTo-WcComparison` (puro): linhas `Source/Name/Target/Unit/Before/After/Delta` (`Delta = After − Before`), `FreeBytesBefore/After/Delta` (só unidades presentes nas duas medições), `Complete`, `Errors`. Falha de coletor nunca falha a ação.
- `-Measure All|Modifying|None` (padrão `All`; o diagnóstico usa `None`).
- `-RequireRestorePoint`: item que precisa de ponto fica `Skipped` (`restorepoint.required-not-available`) se não houver ponto utilizável (criado agora ou recente).
- Ganchos: `Register-WcPlanHook -Name Measure|RestorePoint`, registrados por `Register-WcBaselineHandler` (`WinCare.Baseline`). O Core continua sem cmdlets do Windows; sem gancho, ponto = `Unavailable/no-provider`.

Resultado do ponto (`New-WcRestorePointOutcome`): `Created` | `Skipped` (`created-recently`: já existe ponto dentro da janela do Windows — padrão 1440 min; o ponto existente é referenciado) | `Unavailable` (`not-windows`, `powershell-edition`, `cmdlet-missing`, `server-sku`, `disabled-by-policy`, `protection-disabled`, `requires-admin`) | `Failed` (`not-verified`, `error`).

Regras que não mudam:
- O WinCare **nunca** liga a Proteção do Sistema e **nunca** altera `SystemRestorePointCreationFrequency` nem outra configuração; só lê.
- `Checkpoint-Computer` só no Windows PowerShell 5.1, SKU cliente, sessão elevada e com a proteção já ligada na unidade do sistema.
- Detecção da proteção: valor `{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}` de `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients` (lista de volumes protegidos, ex. `...:(C%3A)`) + política `DisableSR`. **Heurística a confirmar em Windows cliente real** (o runner do CI é Windows Server: só valida o caminho `server-sku`).
- Após `Checkpoint-Computer`, o ponto só conta como `Created` se aparecer um número de sequência novo em `Get-ComputerRestorePoint`.

Histórico (`Add-WcHistory`, uma linha JSON por item): além dos campos F3, `reversibility`, `restorePoint {status, reason, sequenceNumber, creationTime, description, detail}`, `freeBytesDelta`, `comparison[]`, `measurementErrors`; `rollbackAvailable` = `RollbackData` ou ponto utilizável.
Relatório de ações: `New-WcActionReport -Plan -Results` ou `-History (Read-WcHistory ...)` → `Export-WcActionReport -Format Json|Html` (HTML codificado, sem scripts, com CSP).
Listagem somente leitura: `Get-WcRestorePoint` → `Status Ok|Unavailable|Error`, `Reason`, `ProtectionEnabled`, `FrequencyMinutes`, `Points[] (SequenceNumber, Created, Description, Type)`.
