# Guia de execução

## Requisitos
- Windows 10/11 (Pro, Enterprise, IoT Enterprise, LTSC) — matriz em `COMPATIBILIDADE.md`.
- Windows PowerShell 5.1 (já vem no Windows) e .NET Framework com WPF (já vem no Windows).
- Administrador **não** é necessário para o diagnóstico. Algumas leituras (ex.: BitLocker, alguns processos protegidos) ficam incompletas sem elevação — isso aparece como "Indeterminado", nunca como valor inventado.

## Modos

| Modo | Comando | Uso |
|---|---|---|
| Interface | `powershell.exe -NoProfile -STA -File .\src\Start-WinCare.ps1` | Técnico no computador |
| Sem interface | `powershell.exe -NoProfile -File .\src\Start-WinCare.ps1 -NoGui -OutputPath .\diag.json` | Sessão remota, coleta em lote |
| Idioma | `-Language en-US` | Sobrepõe a configuração salva |
| Sem diagnóstico automático | `-NoAutoDiagnostic` | Abrir a janela sem coletar |
| Release verificado | `powershell.exe -NoProfile -File .\Install-WinCare.ps1 -Version 0.1.0` | Distribuição (após F6) |

- Se o host não for STA (ex.: `pwsh`), o `Start-WinCare.ps1` reabre a si mesmo no Windows PowerShell 5.1 com `-STA`.
- Nada é alterado ao abrir. Na v0.1.0 só existem ações de leitura.

## Por que não `irm | iex`
Executar texto baixado direto na memória não permite verificar autor nem integridade, ignora a política de execução e não deixa rastro do que rodou. O WinCare usa um inicializador local (`bootstrap/Install-WinCare.ps1`) que:
1. baixa só do endereço oficial fixado no próprio script, por HTTPS;
2. confere o SHA-256 do pacote com o manifesto (e, se informado, com `-ExpectedSha256` obtido por outro canal);
3. extrai com proteção contra caminhos maliciosos;
4. exige catálogo `WinCare.cat` e scripts **assinados (Authenticode)** por um certificado cuja impressão digital está fixada no inicializador;
5. guarda o pacote verificado em cache por versão e reverifica a cada execução;
6. abre a interface sem `-ExecutionPolicy Bypass`.

O "um comando" é este inicializador assinado, obtido por canal confiável (compartilhamento interno, release assinado ou cópia do técnico).

## Dados gravados
`%LOCALAPPDATA%\WinCare\` — `settings.json`, `logs\wincare-AAAAMMDD.jsonl` (auditoria), `reports\`, `app\<versão>\` (cache do release). Variável `WINCARE_DATA_ROOT` muda a pasta (testes e execução portátil).
