# Relatório de limitações — v0.1.0 (2026-11-16)

## O que NÃO foi feito/verificado
| Item | Situação | Consequência |
|---|---|---|
| Execução no Windows real | Não houve. Desenvolvimento em Zorin OS (Linux) com pwsh 7.7.0 | Nada está homologado; interface WPF nunca foi aberta |
| Interface WPF | Validada só estaticamente (XML, chaves de recurso, nomes, contraste) | Erros de runtime do WPF (bindings, templates, layout, DPI) só aparecem no Windows |
| Windows PowerShell 5.1 | Compatibilidade checada por PSScriptAnalyzer + regras próprias; testes rodaram em pwsh 7 | Diferenças de runtime 5.1 × 7 (ex.: serialização JSON, encoding) só aparecem no Windows |
| CIM/WMI, registro, Authenticode, `Test-FileCatalog` | Mockados no Linux | Nomes de propriedades e comportamento real (ex.: `CatalogItems`/`PathItems` do `Test-FileCatalog -Detailed`) precisam do kit para confirmar |
| Certificado de assinatura | Não existe | O bootstrapper rejeita qualquer pacote (falha fechada, por design) |
| URL oficial / repositório público | Não criado (exige autorização) | `Install-WinCare.ps1` recusa a URL placeholder |
| CI (GitHub Actions) | Arquivo pronto, nunca executado | Roda só quando o repositório for publicado |
| `New-ReleasePackage.ps1` | Escrito, nunca executado (exige Windows + certificado) | Fase F6 |
| Códigos dos ícones Segoe MDL2 | Escolhidos de memória | Conferir no checklist (gui.icons) |
| EditionID de IoT/LTSC | Valores esperados, não confirmados em imagem real | Kit registra o valor real |

## Limitações de projeto (conhecidas)
- CPU é uma amostra de 1 s; memória é pontual. Alertas dessas métricas são informativos e pedem nova coleta.
- CPU por processo é tempo acumulado, não % atual.
- Inicialização lista chaves Run e pastas; tarefas agendadas e serviços ficam para a F3.
- Sinais de gerenciamento podem falhar (ex.: GPO local sem chaves em `Policies\Microsoft`); por isso o perfil Corporativo bloqueia ações sensíveis mesmo sem detecção.
- `TotalProcessorTime`/`Company` de processos protegidos não aparecem sem elevação.
- Integridade (SFC/DISM/chkdsk), otimização, Office e rollback: páginas informativas, sem execução (F3–F5).
- Rollback (F5): só existe onde é viável — ponto de restauração do sistema antes de ações de risco alto (opcionalmente médio), e só se a Proteção do Sistema **já** estiver ligada. Limpeza de temporários, SFC/DISM e ReTrim não podem ser desfeitos. Windows Server não tem Restauração do Sistema. O Windows cria no máximo um ponto a cada 24 h (padrão): nesse caso o WinCare registra "não criado (recente)" e referencia o ponto existente.
- Antes/depois: o espaço livre é da unidade inteira; outros programas podem alterá-lo durante a ação. A medida da pasta da ação mostra o efeito direto.
- Tema escuro: ComboBox foi evitado (template padrão do WPF não respeita fundo escuro); controles nativos como barras de rolagem e diálogos seguem o tema do sistema.
- O kit inclui o Pester 5 (Apache-2.0) copiado da máquina de build para uso interno em laboratório; não é redistribuído no repositório (`tools/` está no `.gitignore`).

## Fora de escopo nesta fase
Instalação de serviços, tarefas agendadas, alterações de registro, publicação de release.
