
# RoboSyncPS

RoboSyncPS is a PowerShell script that uses `robocopy` to synchronize files from a source directory to multiple destination directories. It supports exclusions and logs the operations. The intended use is automated headless operation. 

## Prerequisites

- Windows operating system
- PowerShell
- Robocopy (included with Windows)

## Configuration

The script uses a `config.json` file for configuration. Below is an example of the configuration file:


```json
{
  "SourceDir": "C:\\YourSourceDirectory\\",
  "DestDirs": [
    "D:\\YourFirstBackupDirectory\\",
    "E:\\YourSecondBackupDirectory\\"
  ],
  "Exclusions": ["temp", "$RECYCLE.BIN", "System Volume Information"]
}
```


- **SourceDir**: The source directory to copy files from.
- **DestDirs**: An array of destination directories to copy files to.
- **Exclusions**: An array of directories to exclude from the copy operation.

**Note:** Customize the `config.json` file according to your specific directory structure. Once done, you can remove any lines starting with `"notes"` if included.

## Usage

### Running the Executable

1. Ensure the `config.json` file is in the same directory as the executable.
2. Run the executable:

   ```powershell
   .\RoboSync.exe
   ```

### Scheduling with Windows Task Scheduler

You can schedule the executable to run at regular intervals using Windows Task Scheduler. Here’s how:

1. **Open Task Scheduler**:

   - Press `Win + R`, type `taskschd.msc`, and press `Enter`.

2. **Create a New Task**:

   - In the Task Scheduler, click on **Create Task...**.

3. **General Tab**:

   - Name your task (e.g., "RoboSync Backup").
   - Optionally, provide a description.
   - Choose "Run whether user is logged on or not" and "Run with highest privileges".

4. **Triggers Tab**:

   - Click **New...** to create a new trigger.
   - Set the task to begin "On a schedule".
   - Configure the schedule to repeat every X hours based on your preference.
   - Click **OK**.

5. **Actions Tab**:

   - Click **New...** to create a new action.
   - Set the action to "Start a program".
   - Browse to the location of `RoboSync.exe` and select it.
   - Click **OK**.

6. **Conditions and Settings Tabs**:
   - Configure any additional conditions or settings as needed.
   - Click **OK** to save the task.

Your task is now scheduled to run `RoboSync.exe` at the specified intervals.

## Logging

The script generates two log files:

- **run.log**: Logs the start and end times of the robocopy operations.
- **error.log**: Logs any errors encountered during the robocopy operations.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

```

```
