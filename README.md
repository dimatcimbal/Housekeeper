# Housekeeper

Posh (PowerShell) automation script that handles the boring parts of Cpp development.

## Usage

1.  Use git submodules to add the script to your repo.

    ```powershell
    git submodule add git@github.com:dimatcimbal/Housekeeper.git Housekeeper 
    ```

2. Create a wrapper script to conveniently invoke Housekeeper/housekeeper.ps1
    ```powershell
    # Wrapper for https://raw.githubusercontent.com/dimatcimbal/Housekeeper/main/housekeeper.ps1
    $scriptPath = Join-Path (Get-Item -Path $PSScriptRoot).FullName "Housekeeper\housekeeper.ps1"
    & $scriptPath @Args
    ```
   
3. Invoke the wrapper as usual
    ```powershell
    .\housekeeper.ps1 -Build
    ```