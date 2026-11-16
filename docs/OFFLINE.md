# Execução offline

1. Em uma máquina com acesso, obtenha do release oficial: `WinCare-<versão>.zip` e `WinCare-<versão>.manifest.json`, e o SHA-256 publicado por outro canal (ticket de mudança, página interna).
2. Copie para a mídia/compartilhamento junto com o `Install-WinCare.ps1` **assinado**.
3. No computador alvo:

```powershell
powershell.exe -NoProfile -File .\Install-WinCare.ps1 -Version 0.1.0 `
  -PackagePath E:\WinCare-0.1.0.zip -ManifestPath E:\WinCare-0.1.0.manifest.json `
  -ExpectedSha256 <hash recebido por outro canal>
```

- Nenhuma conexão é feita com `-PackagePath`.
- As mesmas verificações do modo online valem (assinatura, catálogo, arquivos extras). Falha = nada é executado.
- `-VerifyOnly` verifica e guarda no cache sem abrir a interface (útil para preparar várias máquinas).
- Cache adulterado é recusado; apague a pasta indicada e rode de novo.

## Kit de validação (sem assinatura)
O kit `WinCare-Validation-<versão>.zip` **não é um release**: não é assinado e o inicializador o rejeita de propósito. Serve só para validar em laboratório/VM — veja `VALIDACAO-WINDOWS.md`. Ele inclui o Pester 5 em `tools/Pester` para máquinas sem internet.
