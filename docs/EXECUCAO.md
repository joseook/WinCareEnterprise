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
| Release verificado | comando de uma linha abaixo, ou `install.ps1 -Version x.y.z` | Distribuição |

- Se o host não for STA (ex.: `pwsh`), o `Start-WinCare.ps1` reabre a si mesmo no Windows PowerShell 5.1 com `-STA`.
- Nada é alterado ao abrir. Na v0.1.0 só existem ações de leitura.

## Comando de uma linha (técnico)
Cole no PowerShell (de preferência como administrador). O comando exato de cada versão fica no README e em `https://wincare.joseok.cloud` (quando publicado):

```powershell
$f="$env:TEMP\wincare-install.ps1"; iwr https://wincare.joseok.cloud/install.ps1 -UseBasicParsing -OutFile $f; if ((Get-FileHash $f -Algorithm SHA256).Hash -eq '<SHA-256 do install.ps1>') { powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File $f } else { Write-Error 'install.ps1 nao confere - nada foi executado' }
```

## Por que não `irm | iex`
Executar texto baixado direto na memória não permite verificar autor nem integridade, ignora a política de execução e não deixa rastro do que rodou. A cadeia do WinCare:

| Etapa | Garantia |
|---|---|
| 1. O comando fixa o SHA-256 do `install.ps1` | Se o site for trocado, o hash não bate e nada roda. O mesmo comando é publicado no README do GitHub (outra origem) para conferência. |
| 2. O `install.ps1` traz a **chave pública RSA-3072** do mantenedor | Âncora de confiança dentro de um arquivo já verificado. |
| 3. Baixa do GitHub Releases o manifesto + assinatura (`.sig`) | O manifesto só é aceito se a assinatura bater com a chave fixada. |
| 4. Confere o SHA-256 do zip com o manifesto assinado | Pacote adulterado é recusado. |
| 5. Extrai com proteção contra caminhos maliciosos e confere **cada arquivo** (nenhum faltando, alterado ou sobrando) | Igual a um catálogo assinado. |
| 6. Cache por versão, reverificado a cada execução | Alteração local é detectada. |
| 7. Abre com `-ExecutionPolicy RemoteSigned` **só no processo** | Em máquinas no padrão `Restricted` funciona; GPO da empresa (`MachinePolicy`/`UserPolicy`) continua prevalecendo. Nunca `Bypass`. |

A chave privada fica só na máquina do mantenedor (fora do repositório e do CI). Authenticode é uma camada **adicional opcional**: quando houver certificado (pago ou SignPath Foundation), basta fixar a impressão digital em `$WcbTrustedThumbprints` — veja `SECURITY-NOTES.md`.

Em empresas com política `AllSigned` via GPO o WinCare não abre até haver assinatura Authenticode confiável — comportamento correto.

## Dados gravados
`%LOCALAPPDATA%\WinCare\` — `settings.json`, `logs\wincare-AAAAMMDD.jsonl` (auditoria), `reports\`, `app\<versão>\` (cache do release). Variável `WINCARE_DATA_ROOT` muda a pasta (testes e execução portátil).
