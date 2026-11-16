# Contrato de ações (F3+)

Toda ação que o WinCare executa segue este contrato. A UI (páginas Otimização rápida/avançada, Integridade, Office) é genérica e lê o catálogo.

## 1. Catálogo — `src/Core/actions.d/<modulo>.json`
```json
{ "actions": [ {
  "Id": "cleanup.user-temp", "Category": "Storage", "Risk": "Low",
  "Modifies": true, "RequiresAdmin": false, "Reversible": false,
  "RequiresWindows": true, "BlockedWhenManaged": false,
  "MinBuild": 10240, "Editions": null,
  "Pages": ["quick", "advanced"],
  "Handler": "Cleanup-UserTemp",
  "TitleKey": "action.cleanup.user-temp", "DescriptionKey": "action.cleanup.user-temp.desc"
} ] }
```
- `Risk`: None (só leitura) | Low | Medium | High. Modifica ⇒ nunca None.
- `Reversible:false` ⇒ a UI mostra "irreversível" e exige confirmação.
- `Touches` com recurso protegido (Defender, Firewall, BitLocker, WindowsUpdate, GroupPolicy, MDM, EDR, VPN, Authentication, Inventory, ExecutionPolicy, UAC, SmartScreen) ⇒ catálogo rejeitado.
- `Pages`: quick | advanced | integrity | office | storage | startup.

## 2. Handler — registrado no fim do próprio `.psm1`, na importação
```powershell
Register-WcActionHandler -Name 'Cleanup-UserTemp' -Preview { param($Context) ... } -Execute { param($Context) ... }
```
- **Preview** não altera nada. Retorna `New-WcActionResult` com o que *seria* feito (itens, bytes estimados).
- **Execute** faz a ação e retorna `New-WcActionResult` com antes/depois medidos.
- Formato (`[pscustomobject]`): `Summary` (string curta, inglês técnico; a UI mostra), `Items` (array de objetos simples para tabela), `BytesBefore`/`BytesAfter`/`BytesFreed` (quando couber), `Output` (texto bruto de comando externo), `ExitCode`, `RollbackData` (para F5; `$null` se irreversível).
- Comandos externos: só por caminho absoluto em `$env:SystemRoot\System32`, argumentos fixos em array (nada vindo de texto livre), saída capturada, `ExitCode` registrado. Progresso via `Write-WcLog` (aparece no console da UI).
- Erros: `throw` com mensagem clara; o plano marca `Failed` e segue.

## 3. Idioma — `src/Localization/pt-BR.d/<modulo>.json` e `en-US.d/<modulo>.json`
Mesmas chaves nos dois. Chave duplicada entre arquivos = erro na carga.

## 4. Testes — `tests/<Modulo>.Tests.ps1`
- Conversores puros com fixtures; I/O com `Mock -ModuleName`.
- Para cada ação que modifica: Preview não chama nada destrutivo (mock de `Remove-Item`/comando com `-Times 0`); Execute só remove o que o Preview listou; caminhos fora da lista permitida são recusados.
- Só ASCII nos `.ps1/.psm1`; sintaxe 5.1.
