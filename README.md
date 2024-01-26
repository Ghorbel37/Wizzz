<h1 align="center">Welcome to Wizzz 👋</h1>
<p>
  <a href="#" target="_blank">
    <img alt="License: GPL--3.0" src="https://img.shields.io/badge/License-GPL--3.0-yellow.svg" />
  </a>
</p>

## Backup filesystem tree like a wizzz
> This script makes a copy of filesystem tree using WizTree and exports each drive tree to CSV,
> then compresses the files in a single archive
> and copies the backup to multiple locations

## Instructions
This script requires having WizTree installed
Place it in the WizTree folder before executing and make sure to execute it with administrator privileges

## Install
This will create a scheduled task that will be run each week
Make sure to run from an elevated powershell promt from WizTree folder

```sh
Wizzz_create_task.ps1
```

## Usage
This will run the script and make a backup
Run with -silent flag to accept all prompts automatically
Make sure to run from an elevated powershell promt from WizTree folder

```sh
Wizzz_backup.ps1 -silent
```

## Author

* Github: [@Ghorbel37](https://github.com/Ghorbel37)

## Show your support

Give a ⭐️ if this project helped you!

***
_This README was generated with ❤️ by [readme-md-generator](https://github.com/kefranabg/readme-md-generator)_
