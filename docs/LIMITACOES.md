# Relatório de limitações — v0.2.0 (2026-11-16)

## Validado em Windows real
Pelo CI (GitHub Actions `windows-latest`, Windows PowerShell 5.1.26100 Desktop, Windows Server):
- Pester com testes de integração (`tests/Windows`): coleta CIM real, RSA no .NET Framework, prévia e execução segura das ações F3/F4, assinatura Authenticode com `AllSigned` por processo.
- Renderização WPF de todas as páginas (tema escuro e claro, pt-BR e en-US) em PNG, sem erros de UI.
- Relatório diagnóstico sem interface (`-NoGui`).

## Homologação manual
- 2026-11-16: v0.2.1 executada pelo mantenedor num **Windows 11 corporativo** (máquina gerenciada) com o comando `irm`: interface, diagnóstico e ações funcionaram sem erros (relato do usuário; sem relatório do kit anexado).

## O que NÃO foi verificado
| Item | Situação | Consequência |
|---|---|---|
| Windows 10 e edições IoT/LTSC | Windows 11 corporativo homologado manualmente; Windows 10/IoT/LTSC não | Edição, `EditionID`, Office e comportamento do usuário final dependem do kit (`docs/VALIDACAO-WINDOWS.md`) |
| Interação humana na interface | Renderização automática, sem cliques reais | Checklist interativo pendente (navegação, cancelamento, diálogos, DPI alto) |
| UAC / botão "Executar como administrador" | Lógica testada; prompt de UAC não pode ser automatizado | Validar em máquina com usuário padrão e com credencial de outra conta |
| `AllSigned` por GPO e AppLocker/WDAC reais | `AllSigned` validado por processo; AppLocker não | Validar em máquina de domínio |
| Ações destrutivas reais (limpeza, SFC/DISM `/RestoreHealth`, ReTrim) no hardware do usuário | Rodam no CI só em modo seguro/prévia | Primeira execução real em laboratório |
| Office instalado | Runner do CI não tem Office | Medição do Word e reparo validados só com mocks |
| `New-ReleasePackage.ps1` (Authenticode do mantenedor) | Não executado | Exige certificado pago; o modelo atual é RSA (gratuito) |
| F6 `winget upgrade` real, `Reset-AppxPackage`, `ipconfig /renew`, `netsh winsock reset` | Só prévia e validação nos testes; no CI só `network.flush-dns` roda de verdade | Primeira execução real em VM cliente com snapshot |
| F6 tabela do winget e saída do `netsh` localizadas | Parsers testados com fixtures pt-BR/en-US (UTF-8 e cp850); codificação real da saída do winget redirecionado (UTF-8 assumido) não conferida | Conferir num Windows pt-BR com winget |
| F6 `Get-AppxPackage` no PowerShell 7 | Erros do módulo Appx no PS 7 viram aviso da seção | Conferir em Windows 11 com PS 7 |
| Códigos dos ícones Segoe MDL2 | Escolhidos de memória | Conferir nas capturas/checklist |

## Limitações de projeto (conhecidas)
- CPU é amostra de 1 s; memória é pontual. Alertas dessas métricas são informativos.
- CPU por processo é tempo acumulado, não % atual.
- Inicialização (página Inicialização) lista chaves Run e pastas. Tarefas agendadas (gatilho ao entrar/ao ligar, fora de `\Microsoft\`) e serviços automáticos de terceiros (fora de `%windir%`, sem assinatura Microsoft) aparecem na página Saúde do sistema (F6), só como informação: o WinCare não desativa tarefas nem serviços.
- Saúde do sistema (F6): eventos são agrupados (fonte, ID, contagem, datas), sem o texto das mensagens. Layout do evento WER 1001 (nome do evento no índice 2, programa no P1) e o código de saída do `powercfg /energy` não foram conferidos em Windows real. Contadores de confiabilidade do disco costumam exigir administrador (a página mostra "Exige administrador"). `w32tm` não é usado (exige administrador e tem saída traduzida); a fonte de horário vem do registro. O runner do CI é Windows Server sem bateria: bateria e relatório de bateria só foram validados com mocks.
- Sinais de gerenciamento podem falhar (GPO local sem chaves em `Policies\Microsoft`); por isso o perfil Corporativo bloqueia ações sensíveis mesmo sem detecção.
- `TotalProcessorTime`/`Company` de processos protegidos não aparecem sem elevação.
- Rollback (F5): só existe onde é viável — ponto de restauração do sistema antes de ações de risco alto (opcionalmente médio), e só se a Proteção do Sistema **já** estiver ligada. Limpeza de temporários, SFC/DISM e ReTrim não podem ser desfeitos. Windows Server não tem Restauração do Sistema. O Windows cria no máximo um ponto a cada 24 h (padrão): nesse caso o WinCare registra "não criado (recente)" e referencia o ponto existente. A detecção da Proteção do Sistema ainda não foi confirmada em Windows cliente.
- Antes/depois: o espaço livre é da unidade inteira; outros programas podem alterá-lo durante a ação. A medida da pasta da ação mostra o efeito direto.
- `irm | iex` confia no HTTPS do site + conta do GitHub; o comando verificado (hash no README) é o indicado para auditoria. Alguns EDRs alertam sobre o padrão `irm | iex`.
- A chave privada RSA de release fica só na máquina do mantenedor (sem HSM). Perda ou vazamento exige nova chave e novo `install.ps1` (ver `SECURITY-NOTES.md`, T7).
- Tema escuro: ComboBox evitado (template padrão do WPF não respeita fundo escuro); barras de rolagem e diálogos seguem o tema do sistema.
- O kit inclui o Pester 5 (Apache-2.0) copiado da máquina de build para uso interno em laboratório; não é redistribuído no repositório (`tools/` está no `.gitignore`).

## Fora de escopo nesta fase
Instalação de serviços, tarefas agendadas, alterações de registro fora das ações do catálogo, telemetria.
