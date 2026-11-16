# WinCare em máquinas corporativas

Este guia cobre como abrir a interface e aplicar as ações de manutenção em parques gerenciados (domínio, Intune, GPO), **sem contornar** nenhum controle da organização. O WinCare nunca altera a política de execução, nunca usa `-ExecutionPolicy Bypass` e não desativa Defender, Firewall, BitLocker, Windows Update, GPO, MDM, EDR, VPN nem autenticação.

## 1. Qual caminho usar

| Situação na máquina | Como abrir | Observação |
|---|---|---|
| Política padrão (`Restricted`/`RemoteSigned`) sem GPO | `irm https://wincare.joseok.cloud/run \| iex` ou o comando verificado do site | O `install.ps1` usa `RemoteSigned` **só no processo** |
| Precisa aplicar ações que exigem administrador | Mesmo comando num PowerShell **como administrador**, ou o botão **Executar como administrador** na interface | Como admin, a cópia verificada fica em `Program Files\WinCare` (só administradores gravam) |
| GPO define `AllSigned` | Pacote assinado com o certificado da organização (seção 3) | O bootstrapper detecta e explica; não tenta contornar |
| GPO define `Restricted` | Nenhum script roda; peça exceção à TI | Mensagem clara, sem contorno |
| AppLocker/WDAC (PowerShell em `ConstrainedLanguage`) | TI libera o editor (publisher) do pacote assinado (seção 3) | WPF não carrega em modo restrito; o app avisa e sai |
| Proxy com autenticação Windows | Funciona: o download usa as credenciais padrão do usuário | |
| Sem internet / rede isolada | Modo offline (`docs/OFFLINE.md`) | |

## 2. Elevação (aplicar otimizações)

- Usuário padrão: a interface mostra **Executar como administrador**. O UAC pede a credencial (pode ser a conta de suporte da TI).
- O processo elevado **não executa nenhum arquivo gravável pelo usuário**: recebe um comando curto (`-EncodedCommand`) que baixa o `install.ps1` desta versão para `Program Files\WinCare\bootstrap`, confere o SHA-256 que está no pacote assinado (`Core\release.json`, coberto pelo manifesto RSA) e o executa. Esse `install.ps1` verifica o release inteiro de novo antes de abrir.
- Pela linha de comando: `install.ps1 -Elevate` faz o mesmo.
- Cada ação continua com prévia, confirmação, registro de auditoria e as regras do perfil (`Corporativo` bloqueia ações de risco alto e respeita sinais de gerenciamento).

## 3. `AllSigned`, AppLocker e WDAC: assinar com o certificado da organização

Certificado público de assinatura de código é pago. Em empresa, o caminho gratuito e mais adequado é a TI assinar com a **PKI interna** (o mesmo certificado que já usa para scripts próprios):

```powershell
# Na máquina de empacotamento da TI (com o certificado de assinatura de código):
.\scripts\Protect-WinCareWithOrgCertificate.ps1 `
    -ReleaseDirectory .\v0.3.0 `                 # zip + manifest + .sig + install.ps1 do GitHub Releases
    -CertificateThumbprint <40 hex> `
    -OutputDirectory D:\deploy\WinCare-0.3.0 `
    -TimestampServer <servidor RFC 3161 da organização>
```

O script:
1. Verifica o release igual ao `install.ps1` (assinatura RSA do manifesto, hash do zip e de cada arquivo, nenhum arquivo extra). Se falhar, não assina nada.
2. Assina todos os `.ps1/.psm1/.psd1` (SHA-256) e grava e assina `WinCare.FileHashes.ps1` com o SHA-256 de **todos** os arquivos (catálogo de ações, XAML, idiomas). O `New-FileCatalog` do Windows PowerShell 5.1 falhou neste pacote no CI, por isso o catálogo `.cat` não é usado.
3. Confere que tudo ficou `Valid` e grava `WINCARE-ORG-SIGNED.json` (hash do manifesto original, assinante, data).

Depois, distribua a pasta para um local só de administradores (ex.: `C:\Program Files\WinCare\0.3.0`) via Intune, ConfigMgr ou GPO, e crie o atalho:

```
powershell.exe -NoProfile -STA -File "C:\Program Files\WinCare\0.3.0\src\Start-WinCare.ps1"
```

- **AppLocker/WDAC:** crie regra de *publisher* para o certificado da organização (não por caminho).
- **Auditoria:** `. .\scripts\Protect-WinCareWithOrgCertificate.ps1; Test-WcOrgFileHashes -Root <pasta>` não deve listar nada (confere a assinatura da lista e acusa arquivo alterado, extra ou faltando).
- Depois de reassinado, o pacote não bate mais com o manifesto RSA (os arquivos mudaram); a assinatura Authenticode da organização passa a ser o controle de integridade.

Validação: `tests/Windows/OrgSigning.Windows.Tests.ps1` roda no Windows real (CI) com um certificado descartável e prova que um processo `AllSigned` carrega a cópia assinada e rejeita a não assinada.

## 4. Sobre `irm | iex`

`irm https://wincare.joseok.cloud/run | iex` é o atalho de conveniência. O que ele executa é o script curto e legível em `/run.ps1`, que só baixa o `install.ps1` da versão, confere o SHA-256 e o roda **como arquivo** (com política de execução e GPO valendo). A confiança desse atalho é a do HTTPS do site + conta do GitHub; o comando "verificado" do site fixa o hash do seu lado e é o indicado para auditoria. Alguns EDRs alertam sobre o padrão `irm | iex` por ser comum em malware: nesse caso use o comando verificado ou o pacote assinado pela organização.

## 5. O que ainda não foi validado

- Execução em Windows 10/11 cliente real ingressado em domínio com `AllSigned` por GPO e com AppLocker (o CI cobre `AllSigned` por processo em Windows Server).
- Fluxo de UAC com credencial de outra conta (OTS) — exige interação humana.

Registre o resultado no checklist de `docs/VALIDACAO-WINDOWS.md`.
