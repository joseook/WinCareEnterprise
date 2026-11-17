# WinCare Enterprise

Ferramenta open source de diagnóstico e manutenção do Windows para técnicos e ambientes corporativos. PowerShell-first, interface WPF, sem instalador, sem `-ExecutionPolicy Bypass`.

> **Estado: v0.3.1 — diagnóstico, manutenção, processos e memória, saúde do sistema, aplicativos e rede; PowerShell 5.1 e 7.** Desenvolvido em Linux e testado no **Windows PowerShell 5.1 e no PowerShell 7 em Windows real** pelo CI (GitHub Actions, Windows Server): Pester, coleta CIM real, renderização WPF das 11 páginas e assinatura Authenticode com `AllSigned`. **Ainda falta homologar em Windows 10/11 cliente** com o checklist interativo (`docs/VALIDACAO-WINDOWS.md`). Matriz em `docs/COMPATIBILIDADE.md`.

## Executar

Abra o PowerShell (**como administrador** para aplicar otimizações) e cole:

```powershell
irm https://wincare.joseok.cloud/run | iex
```

Ou o comando **verificado**, com o hash do `install.ps1` fixado aqui no README (canal independente do site):

```powershell
$f="$env:TEMP\wincare-install.ps1"; iwr https://wincare.joseok.cloud/install.ps1 -UseBasicParsing -OutFile $f; if ((Get-FileHash $f -Algorithm SHA256).Hash -eq 'D0099E99AE846DA2508D209B82584AA5F3276589E04670EE71AF2ACCE26AB861') { powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File $f } else { Write-Error 'install.ps1 nao confere - nada foi executado' }
```

Os dois só executam o `install.ps1` da versão se o SHA-256 conferir. Ele baixa o pacote do GitHub Releases e verifica a assinatura RSA do manifesto (chave fixada), o hash do zip e o de cada arquivo antes de abrir. Como administrador, a cópia verificada fica em `Program Files\WinCare`. Na interface, **Executar como administrador** reabre pelo mesmo caminho verificado.

- **PowerShell 7:** usado automaticamente quando instalado em `Program Files` (senão, o 5.1 que vem no Windows). Forçar: `install.ps1 -PowerShellHost WindowsPowerShell|PowerShell7`.
- Máquinas corporativas (`AllSigned`, AppLocker/WDAC, proxy, Intune/GPO): `docs/CORPORATIVO.md`.
- Sem internet: `docs/OFFLINE.md`. Detalhes da cadeia: `docs/EXECUCAO.md`.

## O que já existe

| Área | Situação |
|---|---|
| Interface WPF: 11 páginas, tema escuro/claro, pt-BR/en-US, console de logs | Renderizada no Windows real (CI); interação manual pendente |
| Diagnóstico somente leitura: edição/build, CPU, RAM, discos HDD/SSD, inicialização, reinício pendente, sinais de gerenciamento, Defender/Firewall (só leitura) | Validado com CIM real no CI |
| Manutenção (F3): limpeza de temporários, ReTrim/análise, SFC, DISM, CHKDSK (leitura) — prévia, confirmação por ação, auditoria, histórico | Testado no CI (prévia e execução segura); ações destrutivas não rodam no CI |
| Office (F4): detecção, suplementos, tempo de abertura do Word (normal × modo seguro), reparo oficial | Testado com mocks + CI sem Office |
| Políticas: 4 perfis, catálogo de ações em lista permitida, recursos protegidos bloqueados | Testado |
| Distribuição: release com manifesto assinado (RSA-3072), `irm \| iex`, comando verificado, elevação segura, assinatura pela PKI da organização | Testado; `AllSigned` validado no CI |
| Processos e memória: pressão de memória, maiores consumidores, suspeita de vazamento, programas em segundo plano (assinatura/local), CPU agora; encerrar processo com proteção a sistema e segurança | Testado no CI (Windows real) |
| Saúde do sistema: eventos críticos (telas azuis, desligamentos, disco, WHEA), falhas de apps, drivers com problema, saúde dos discos, tarefas/serviços de inicialização de terceiros, bateria, Windows Update (leitura) | Testado no CI; bateria só com mocks |
| Aplicativos e reparos: programas instalados, desinstaladores quebrados, atualizações via winget (só as selecionadas), apps da Store com problema | Testado no CI (leitura); atualizar/redefinir não roda no CI |
| Rede: adaptadores, conectividade (gateway, DNS, HTTP/HTTPS), proxy, VPN; limpar cache DNS, renovar IP, redefinir Winsock (com confirmação; bloqueados em máquina gerenciada) | Testado no CI; só o cache DNS é alterado no CI |
| F5: comparação antes/depois e ponto de restauração (só se a Proteção do Sistema já estiver ligada) | Testado (lógica + CI); criação real de ponto pendente em Windows cliente |

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
