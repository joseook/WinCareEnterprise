# Metodologia de métricas e alertas

Princípios: dado ausente = "Indeterminado" (nunca estimado); cada alerta tem regra e limiar explícitos; **não existe "nota de saúde"**. Os limiares são escolhas conservadoras do projeto, **não** padrões publicados pela Microsoft, e são configuráveis (`Get-WcDefaultThreshold`).

## Fontes

| Métrica | Fonte | Observação |
|---|---|---|
| Edição/build | `Win32_OperatingSystem` + `HKLM\...\Windows NT\CurrentVersion` (`EditionID`, `DisplayVersion`, `UBR`) | Windows 11 = build ≥ 22000 (o registro ainda diz "Windows 10" no `ProductName`) |
| CPU % | 2 amostras de `Win32_PerfRawData_PerfOS_Processor` (`_Total`) com 1 s de intervalo: `100 × (1 − ΔPercentProcessorTime / ΔTimestamp_Sys100NS)` | Classe não localizada (evita nomes de contador traduzidos do `Get-Counter`) |
| RAM | `Win32_ComputerSystem.TotalPhysicalMemory`, `Win32_OperatingSystem.FreePhysicalMemory` | Amostra pontual |
| Discos | `Win32_LogicalDisk` (DriveType=3) + `MSFT_Partition` → `MSFT_PhysicalDisk` (`MediaType` 3=HDD, 4=SSD, 5=SCM; `BusType` 17=NVMe) | Sem correspondência = "Unknown" |
| Tempo ligado | `LastBootUpTime` | Com Inicialização Rápida, desligar não zera o contador |
| Reinicialização pendente | Chaves `CBS\RebootPending` e `WindowsUpdate\Auto Update\RebootRequired` | `PendingFileRenameOperations` só é informativo (comum e frequentemente benigno) |
| Processos | `Get-Process` — working set; CPU = tempo acumulado | Não é % atual |
| Inicialização | `Win32_StartupCommand` | Não inclui tarefas agendadas e serviços (F3) |
| Gerenciamento | Domínio, `CloudDomainJoin\JoinInfo`, `Enrollments\*\ProviderID`, `HKLM\SOFTWARE\Policies\Microsoft` | São **sinais**, não prova |

## Alertas

| Id | Severidade | Regra |
|---|---|---|
| disk-system-critical | Crítico | Disco do sistema < 5% livre **ou** < 5 GB |
| disk-system-low | Atenção | Disco do sistema < 10% **ou** < 10 GB |
| disk-other-low | Atenção | Outro volume fixo < 10% |
| disk-system-hdd | Info | Windows em HDD |
| memory-high | Atenção | RAM em uso ≥ 90% na coleta |
| cpu-high-sample | Info | CPU ≥ 90% na amostra de 1 s |
| reboot-pending | Atenção | Sinal forte de reinicialização pendente |
| uptime-long | Info | Ligado há ≥ 14 dias |
| windows-out-of-matrix | Info | Edição/build fora da matriz planejada |
| defender-inactive | Info | Serviço do Defender inativo (pode haver outro AV) |
| firewall-profile-off | Atenção | Algum perfil do firewall desligado |
