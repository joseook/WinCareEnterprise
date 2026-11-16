# Validação em Windows real

Objetivo: transformar "implementado" em "validado". Use **máquina virtual descartável** (Hyper-V, VirtualBox, VMware) com snapshot. Na v0.1.0 tudo é somente leitura, mas a regra vale desde já.

## 1. Gerar o kit (Linux ou Windows)
```bash
pwsh -File scripts/New-ValidationPackage.ps1
cat dist/WinCare-Validation-0.1.0.zip.sha256
```
Anote o SHA-256 **por outro canal** (ex.: mensagem para você mesmo).

## 2. Na VM Windows
```powershell
# conferir o hash antes de qualquer coisa
(Get-FileHash .\WinCare-Validation-0.1.0.zip -Algorithm SHA256).Hash
Expand-Archive .\WinCare-Validation-0.1.0.zip -DestinationPath C:\WinCareKit
Get-ChildItem C:\WinCareKit -Recurse | Unblock-File      # só depois de conferir o hash
cd C:\WinCareKit\WinCare-Validation-0.1.0
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Windows\Invoke-WinCareValidation.ps1 -Interactive
```
- `-ExecutionPolicy RemoteSigned` vale só para esse processo e **não** contorna GPO (se houver política de grupo, ela prevalece e o kit não roda — o que é correto; use uma VM fora do domínio). Nunca use `Bypass`. O release assinado dispensa isso.
- Rode duas vezes: como usuário padrão e como administrador.

## 3. O que o kit faz
1. Registra edição, build, PowerShell, .NET, idioma, admin, política de execução, se é VM.
2. Confere todos os arquivos do kit com `SHA256SUMS.txt`.
3. Roda toda a suíte Pester, incluindo `tests/Windows` (CIM real, XAML no WPF real, Authenticode real).
4. Roda o diagnóstico sem interface e exporta JSON e HTML.
5. Com `-Interactive`: abre a interface e pergunta os 12 itens do checklist (abrir, responsividade, painel coerente com o Gerenciador de Tarefas, 11 páginas, tabelas, cancelar, tema, idioma, exportar, console, ícones, DPI).

Saída: `validation-results\<PC>-<data>\` com `validation-report.md/json`, `pester-results.xml`, `diagnostic.json/html`.

## 4. Critério de homologação
Uma linha da matriz só vira "Validado" com: 0 FAIL no relatório daquela edição/build, checklist completo (sem SKIP) e o relatório anexado em `docs/validacoes/`.

## 5. F5 — antes/depois e ponto de restauração (pendente de validação em cliente real)
O CI (`windows-latest`, Windows Server) valida a medição real de espaço livre e o caminho `server-sku`; nunca cria ponto (o teste bloqueia `Checkpoint-Computer`). Em VM **Windows 10/11 cliente** com snapshot, como administrador, no Windows PowerShell 5.1:
1. Proteção do Sistema **desligada** em C: → `Get-WcRestorePointAvailability` deve dar `protection-disabled` e nada deve ser criado.
2. Ligue a proteção manualmente (Painel de Controle) → `Get-WcRestorePointAvailability` deve dar `Available=True`; confirme que o valor `SPP\Clients` lista `(C%3A)`.
3. `New-WcRestorePoint -Description 'WinCare validation'` → `Created` com número novo em `Get-ComputerRestorePoint`.
4. Repita em seguida → `Skipped / created-recently` referenciando o ponto do passo 3.
5. `Get-WcRestorePoint` lista os pontos; como usuário padrão → `requires-admin`.
Registre os resultados em `docs/validacoes/`. Até lá, a detecção por `SPP\Clients` é considerada **não validada**.
