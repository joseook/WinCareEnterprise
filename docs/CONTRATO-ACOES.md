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

## 6. Páginas de análise (F6+: processos, saúde, aplicativos, rede)

Cada módulo de área exporta **uma** função de dados para a sua página, executada pela interface num job em segundo plano:

```powershell
Get-Wc<Area>PageData [-Context <New-WcContext>]  ->  [pscustomobject]@{
    PageId   = 'processes' | 'health' | 'apps' | 'network'
    Sections = @( [pscustomobject]@{
        Id       = 'top-memory'                  # único na página
        TitleKey = 'section.processes.top-memory' # chave de idioma do título
        NoteKey  = 'section.processes.top-memory.note' # opcional: texto explicativo
        Rows     = @( [pscustomobject]@{ ... } )  # colunas = nomes de propriedade; cabeçalho = col.<Propriedade>
        Severity = 'Info' | 'Warning' | 'Critical' # opcional: destaque da seção
    } )
    Findings = @( achados no formato de New-WcFinding )  # opcional
    Errors   = @( 'seção: mensagem' )                     # coleta que falhou não derruba a página
}
```

Regras:
- Somente leitura. Nunca lança exceção: falha de uma seção vai para `Errors`.
- Linhas já formatadas para exibição (bytes legíveis, datas locais curtas). Valores numéricos para ordenação podem ir numa coluna extra cujo nome termina em `Raw` (a interface a esconde).
- Toda coluna `X` precisa de `col.X` nos dois idiomas (fragmento do módulo).
- As ações da área vão no catálogo com `"Pages": ["<página>"]` e aparecem embaixo das seções, com prévia e confirmação como nas demais.
- Seção só com nota é permitida (`Rows = @()` + `NoteKey`), ex.: `no-ram-cleaner` na página de processos.

### 6.1 Parâmetros de ação vindos da seleção na interface

Ações que agem sobre um item escolhido numa tabela (hoje só `process.end`) recebem a escolha **no contexto**, não no catálogo:

```powershell
$ctx = New-WcContext -IsAdmin ... -Build ...
$ctx.Parameters = @{ 'process.end' = @{ ProcessId = 1234; ProcessName = 'notepad'; Force = $false } }
# equivalente: Set-WcProcessEndRequest -Context $ctx -ProcessId 1234 -ProcessName 'notepad' [-Force]
```

- Chave = id da ação; valores simples (número, texto, booleano). Nada vira comando ou argumento livre. `Force` só conta se for booleano `$true`.
- `ProcessId` e `ProcessName` vêm das colunas `ProcPid` e `Name` da linha selecionada. O nome protege contra reuso de PID entre a prévia e a execução (`pid-mismatch`).
- Fluxo da interface: seleção → `Set-WcProcessEndRequest` → `New-WcPlan` + `Invoke-WcPlan -DryRun` (prévia: o que seria encerrado e quanta memória usa) → diálogo de confirmação com duas escolhas, **Fechar** (padrão) e **Forçar encerramento** (avisa que o que não foi salvo se perde) → se o usuário escolher forçar, `Set-WcProcessEndRequest ... -Force` **antes** de `Invoke-WcPlan -ConfirmCallback`. Sem `Force`, um processo que não fecha sozinho termina como `Failed` ("not forced"); nunca é morto.
- O handler relê o processo e reaplica a lista de bloqueio na execução; recusa vira `Failed` com os códigos (texto em `processes.refuse.<código>`). Tudo vai para o log de auditoria (categoria `Processes`).

### 6.2 Página `processes` (`WinCare.Processes`)

`Get-WcProcessesPageData [-TopCount 25] [-SampleCount 3] [-SampleIntervalSeconds 3] [-GrowthTopCount 15] [-SignatureCheckCount 25] [-CpuTopCount 10]` leva cerca de `SampleCount × SampleIntervalSeconds` s (padrão ~6 s); a mesma amostragem alimenta crescimento, CPU e falhas de página.

| Seção | Colunas |
|---|---|
| `memory-overview` | `Metric`, `Value`, `Status`, `ProcThreshold`, `ProcStatusRaw` |
| `top-memory` | `Name`, `ProcPid`, `ProcWorkingSet`, `ProcPrivate`, `Description`, `Company`, `Path`, `ProcKind`, `ProcServices`, `ProcWorkingSetRaw`, `ProcPrivateRaw` |
| `growth` | `Name`, `ProcPid`, `ProcSamples`, `ProcGrowth`, `Status`, `ProcStatusRaw`, `ProcGrowthRaw` |
| `review` | `Name`, `ProcPid`, `ProcInstances`, `Path`, `ProcLocation`, `ProcSignature`, `ProcSigner`, `ProcKind`, `ProcSignatureRaw` |
| `cpu-now` | `Name`, `ProcPid`, `ProcCpuPercent`, `CpuSecondsTotal`, `ProcCpuPercentRaw` |
| `no-ram-cleaner` | só nota (`processes.note.no-ram-cleaner`) |

`ProcStatusRaw` (`Ok/Pressure/Critical/Info/Unknown/Growing/Stable`) e `ProcSignatureRaw` (status do Authenticode ou `NotChecked`) são códigos para a interface colorir/filtrar; ficam escondidos como as demais colunas `Raw`.

Limites (`Get-WcProcessesThreshold`): memória disponível < 15 % = pressão, < 5 % = crítico; carga de confirmação ≥ 80 % do limite = pressão, ≥ 95 % = crítico; arquivo de paginação ≥ 80 % = pressão; `Memory\Pages Input/sec` ≥ 1000/s = pressão (amostra curta); crescimento = bytes privados sobem em **todas** as amostras, ≥ 10 MB e ≥ 5 % (heurística, não prova). A assinatura é verificada (com cache) só em executáveis fora de `%SystemRoot%`, primeiro os de pastas graváveis, até `SignatureCheckCount`. A linha de comando dos processos nunca entra nas linhas (pode conter segredos).

Ações (`actions.d/f6-processes.json`):
- `process.end` — Medium, modifica, `Reversibility: None` (só perfil Avançado). Um PID por vez. Recusa (listas no topo do módulo): PID 0/4; processos essenciais (System, Idle, Registry, smss, csrss, wininit, winlogon, services, lsass, svchost, dwm, fontdrvhost, explorer…); segurança/EDR/VPN/gerenciamento (Defender e Defender for Endpoint, Intune, ConfigMgr, CrowdStrike, SentinelOne, Sophos, Cisco Secure Client, GlobalProtect, FortiClient, Zscaler, OpenVPN, WireGuard… por nome, empresa do arquivo ou pasta do Defender) — nem administrador libera; quem hospeda serviços; contas do sistema; sessão 0 (quando o WinCare não roda na sessão 0); o próprio WinCare; processo de outro usuário ou de dono desconhecido sem administrador. Primeiro `CloseMainWindow` (espera 10 s); `Stop-Process` só com `Force`. `Measure`: `ProcessRunning` e `ProcessWorkingSet` do PID.
- `memory.schedule-diagnostic` — Low. Não há opção documentada do `MdSched.exe` para agendar sem janela, então a ação **abre** o Diagnóstico de Memória do Windows (pode pedir UAC) e o usuário escolhe "reiniciar agora" ou "na próxima inicialização". O WinCare nunca reinicia o computador.
- Não há "limpador de RAM" (EmptyWorkingSet, esvaziar a lista de espera): é placebo ou piora (o Windows relê do disco o que foi descartado). Explicação em `processes.note.no-ram-cleaner`.
