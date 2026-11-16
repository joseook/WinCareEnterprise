# Execução offline

1. Em uma máquina com acesso, baixe do release oficial (GitHub Releases, `v<versão>`): `WinCare-<versão>.zip`, `WinCare-<versão>.manifest.json`, `WinCare-<versão>.manifest.json.sig` e `install.ps1`.
2. Confira o SHA-256 do `install.ps1` com o publicado no README do GitHub (canal independente do site). O SHA-256 do zip também está no README do release e no site.
3. Copie os quatro arquivos para a mídia/compartilhamento. O `.sig` precisa ficar ao lado do manifesto.
4. No computador alvo (como administrador, a cópia verificada vai para `Program Files\WinCare`):

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File E:\install.ps1 `
  -PackagePath E:\WinCare-0.2.0.zip -ManifestPath E:\WinCare-0.2.0.manifest.json `
  -ExpectedSha256 <hash do zip recebido por outro canal>
```

- Nenhuma conexão é feita com `-PackagePath`.
- As mesmas verificações do modo online valem: assinatura RSA do manifesto com a chave fixada no `install.ps1`, hash do zip, hash de cada arquivo, nenhum arquivo extra. Falha = nada é executado.
- `-VerifyOnly` verifica e guarda no cache sem abrir a interface (útil para preparar várias máquinas).
- Cache adulterado é recusado; apague a pasta indicada e rode de novo.
- `-Elevate` não funciona offline: abra o PowerShell como administrador e rode o comando acima.
- `AllSigned`/AppLocker: use o pacote reassinado pela TI (`docs/CORPORATIVO.md`).

## Kit de validação (sem assinatura)
O kit `WinCare-Validation-<versão>.zip` **não é um release**: não tem manifesto assinado e o inicializador o rejeita de propósito. Serve só para validar em laboratório/VM — veja `VALIDACAO-WINDOWS.md`. Ele inclui o Pester 5 em `tools/Pester` para máquinas sem internet.
