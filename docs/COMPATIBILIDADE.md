# Matriz de compatibilidade

**Legenda:** Planejado = o código trata o caso; Testado-Linux = lógica coberta por testes com dados simulados; **Validado = executado com o kit em Windows real, com relatório anexado.** Nada abaixo está validado ainda.

## Sistemas

| Sistema | EditionID esperado | Suporte | Validado em Windows real |
|---|---|---|---|
| Windows 10 Pro (22H2) | Professional | Planejado, Testado-Linux | Não |
| Windows 10 Enterprise (22H2) | Enterprise | Planejado, Testado-Linux | Não |
| Windows 10 Enterprise LTSC 2019/2021 | EnterpriseS | Planejado, Testado-Linux | Não |
| Windows 10 IoT Enterprise | IoTEnterprise | Planejado | Não |
| Windows 10 IoT Enterprise LTSC 2021 | IoTEnterpriseS | Planejado, Testado-Linux | Não |
| Windows 11 Pro (23H2/24H2) | Professional | Planejado | Não |
| Windows 11 Enterprise (23H2/24H2) | Enterprise | Planejado, Testado-Linux | Não |
| Windows 11 IoT Enterprise | IoTEnterprise | Planejado, Testado-Linux | Não |
| Windows 11 Enterprise / IoT Enterprise LTSC 2024 | EnterpriseS / IoTEnterpriseS | Planejado | Não |
| Home, Education, Server | Core*, Education, Server* | Diagnóstico funciona; fora da matriz (alerta Info) | Não |

Não tenho certeza de que todos os `EditionID` de IoT/LTSC acima correspondem exatamente ao que cada imagem reporta — o kit registra o valor real e esta tabela deve ser corrigida com ele.

## Componentes

| Componente | Requisito | Verificado por |
|---|---|---|
| Windows PowerShell 5.1 | Base garantida (vem em todo Windows suportado) | CI Windows real (5.1.26100) + kit (env.ps51) |
| PowerShell 7 (7.4+) | Opcional, preferido quando instalado em `Program Files\PowerShell\7` (`install.ps1 -PowerShellHost Auto`) | CI Windows real (7.6.9): Pester, WPF das 11 páginas, `-NoGui` |
| Recursos só do 5.1 (ponto de restauração: `Checkpoint-Computer`, `Get-ComputerRestorePoint`) | No PS 7, executados num `powershell.exe` filho com script fixo | `tests/Windows/F5.Windows.Tests.ps1` (ponte) |
| WPF (.NET Framework 4.x) | Interface | `tests/Windows` (XamlReader) + checklist |
| Thread STA | Interface | `tests/Windows` + relançamento automático |
| CIM `root/cimv2` | Diagnóstico | `tests/Windows` |
| CIM `root/Microsoft/Windows/Storage` | Tipo de disco | `tests/Windows`; ausente → "Unknown" |
| Fonte Segoe MDL2 Assets | Ícones | Checklist (gui.icons) |
| Get-MpComputerStatus / Get-NetFirewallProfile | Estado de proteção | Opcional; ausente → "Indeterminado" |

## Funcionalidades × homologação

| Funcionalidade | Linux (automático) | Windows real |
|---|---|---|
| Coleta de sistema, disco, processos, inicialização, gerenciamento | Testado com mocks | Pendente |
| Alertas e relatórios JSON/HTML | Testado | Pendente |
| Motor de políticas, perfis, dry-run, auditoria | Testado | Pendente |
| Interface: abrir, navegar, responsividade, cancelar, tema, idioma, exportar | Só XAML estático | Pendente |
| Bootstrapper: assinatura, catálogo, cache, offline | Testado com mocks | Pendente (precisa de certificado) |

## Como registrar uma validação
Rode o kit (`VALIDACAO-WINDOWS.md`), anexe `validation-report.md` em `docs/validacoes/<data>-<edição>-<build>.md` e troque "Não"/"Pendente" pelo link do relatório.
