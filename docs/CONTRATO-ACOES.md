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
  Valores atuais: limpeza de temporários, ReTrim, `sfc /scannow`, `DISM /RestoreHealth`, `apps.winget-upgrade`, `apps.store-reset`, `network.flush-dns` e `network.renew-ip` = `None`; `network.reset-winsock` = `RestorePoint` (o catálogo Winsock fica no Registro, que a Restauração do Sistema reverte); todo o resto = `ReadOnly`.
- `Touches` com recurso protegido (Defender, Firewall, BitLocker, WindowsUpdate, GroupPolicy, MDM, EDR, VPN, Authentication, Inventory, ExecutionPolicy, UAC, SmartScreen) ⇒ catálogo rejeitado.
- `Pages`: quick | advanced | integrity | office | storage | startup | processes | health | apps | network.

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


## 7. Seleção do usuário (ids escolhidos numa seção)

Algumas ações agem sobre linhas que o usuário marca numa seção (ex.: pacotes do winget). Os handlers continuam recebendo **só o contexto**; a seleção viaja nele:

```powershell
$ctx = New-WcContext -IsAdmin ... -IsManaged ... -Build ...
$ctx.Selection = @{
    'apps.winget-upgrade' = @('Microsoft.Edge', 'Mozilla.Firefox')   # valores da coluna PackageId
    'apps.store-reset'    = @('Microsoft.WindowsCalculator_11.2210.0.0_x64__8wekyb3d8bbwe')  # coluna PackageFullName
    'apps.open-repair'    = @('Nome do app')                          # coluna Name (só exibido no resumo)
}
$plan = New-WcPlan ... -Context $ctx
Invoke-WcPlan -Plan $plan -Context $ctx -DryRun   # prévia lista exatamente os ids selecionados
```

- Chave = id da ação no catálogo; valor = lista de strings (um único id também é aceito). Sem chave ⇒ lista vazia: a prévia diz que nada foi selecionado e o Execute recusa.
- A interface só passa valores copiados das linhas da seção (nunca texto digitado). O handler valida tudo de novo e **falha fechado** (lança exceção, nada roda) se um valor for inválido:
  - `apps.winget-upgrade`: cada id casa com `^[A-Za-z0-9._+-]{1,128}$` e não começa com `-` (impede `--all`, `-h`...); duplicados (sem diferenciar maiúsculas) são removidos; no máximo 50.
  - `apps.store-reset`: exatamente **um** `PackageFullName` (`Nome_Versão_Arquitetura_Recurso_Editor`), do usuário atual, que não seja framework.
  - `apps.open-repair`: opcional; só aparece no resumo (caracteres de controle removidos, até 128). Nada da seleção é passado ao `ms-settings:`.
- Leitura no handler: `Get-WcAppsSelection -Context $Context -ActionId '<id>'` (`WinCare.Apps`).

## 8. Páginas F6: aplicativos e rede

| Página | Função | Seções (`Id`: colunas) |
|---|---|---|
| `apps` | `Get-WcAppsPageData` | `installed`: Name, Version, Publisher, InstallDate, Size, SizeRaw, Scope, Executable, Uninstall · `broken-uninstall`: Name, Version, Scope, Executable · `winget-updates`: Name, PackageId, Version, Available, Source (falha: Status, Detail) · `store-problems`: Name, Version, Status, PackageFullName |
| `network` | `Get-WcNetworkPageData` | `adapters`: Name, Description, Status, LinkSpeed, IPv4, IPv6, Gateway, DnsServers, Dhcp · `connectivity`: Check, Target, Status, Latency, LatencyRaw, Detail · `proxy`: Source, Item, Value · `vpn`: Name, Type, Status, Source |

- `winget-updates`: `NoteKey` explica o estado (`.note`, `.note.none`, `.note.partial`, `.note.failed`, `.note.not-found`, `.note.system-context`). O winget é um alias por usuário (`%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe`): como SYSTEM, ou sem App Installer, a seção diz por quê e não roda nada. A saída `upgrade` não tem formato JSON documentado; a tabela de texto é lida por posição de coluna (cabeçalho localizado) e linhas que não alinham ficam fora (contadas, nota `.partial`), nunca adivinhadas.
- `connectivity`: `NoteKey` = `section.network.connectivity.verdict.<ok|no-network|dns|captive-portal|proxy-auth|internet-or-proxy|gateway-icmp|partial|unknown>`. Sondas: ping ao gateway IPv4, `Resolve-DnsName www.msftconnecttest.com`, `http://www.msftconnecttest.com/connecttest.txt` (corpo exato, como o NCSI do Windows) e `HEAD https://www.microsoft.com/` (o msftconnecttest não tem certificado HTTPS válido). Sem cookies, credenciais, User-Agent ou redirecionamento.
- Ações: `apps.winget-upgrade` (Medium, BlockedWhenManaged, uma execução do winget por id, nunca `--all`), `apps.store-reset` (Medium, `Reset-AppxPackage`, apaga os dados locais do app; indisponível antes do build 19041), `apps.open-repair` (Low, só abre Configurações), `network.flush-dns` (Low), `network.renew-ip` (Medium, admin, BlockedWhenManaged), `network.reset-winsock` (High, admin, BlockedWhenManaged, `RestorePoint`, exige reinício — o WinCare nunca reinicia).
