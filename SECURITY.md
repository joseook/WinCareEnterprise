# Segurança

## Garantias de projeto
- **Abrir não altera nada.** Na v0.1.0 o catálogo só contém ações de leitura (teste automático garante).
- **Proteções fundamentais intocáveis:** ação que declara tocar Defender, Firewall, BitLocker, Windows Update, GPO, MDM, EDR, VPN, autenticação, inventário, política de execução, UAC ou SmartScreen é rejeitada ao carregar o catálogo.
- **Lista permitida:** só ações do catálogo com handler registrado em código; o catálogo não carrega código; ids desconhecidos geram erro.
- **Privilégio mínimo:** diagnóstico roda como usuário padrão; ações que exigem admin são bloqueadas sem elevação.
- **Sem execução dinâmica:** nenhum `Invoke-Expression`, `DownloadString`, `Set-ExecutionPolicy` ou `-ExecutionPolicy Bypass` no código distribuído (teste automático via AST).
- **Relatório HTML** codifica todo valor (nomes de processo, rótulos, comandos), sem scripts e com CSP restritiva.
- **Auditoria:** cada passo do plano vai para `%LOCALAPPDATA%\WinCare\logs\*.jsonl`.

## Cadeia de distribuição
Ver `docs/EXECUCAO.md`. Âncoras de confiança (URL oficial e impressões digitais do certificado) ficam no inicializador assinado. Hash do mesmo servidor = só integridade de transporte; autenticidade = Authenticode + catálogo assinado + nenhum arquivo extra. Qualquer falha de verificação interrompe a execução.

## Modelo de ameaças e gate
`SECURITY-NOTES.md` (nível de risco, ameaças, resultado do baseline e decisão).

## Reportar vulnerabilidades
Repositório ainda não publicado. Depois da publicação: GitHub Security Advisories (relato privado). Não abra issue pública para vulnerabilidade.
