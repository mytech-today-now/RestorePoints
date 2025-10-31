Implement the following enhancement to the application.  Do the enhancement first.  Follow the Rules and Guidelines for the project.  Plan out you actions.  Work logically through the process.  Be sure to cover all of the instances where the enhancement alters the application.  Handle errors and fallback to seamless solutions.
Log each fix/enhancement as an Issue/Error on Github for the project with the required proper 'bug' documentation.
Be sure the Issue has the proper Assignees, Labels, bug, Something isn't working, critical, etc for the Issue.
If the changes are code related make sure the test cases run to 98% success.  After the resolution of the Issue, close the Issue on GitHub with the proper documentation.
enhancement:

Generate a powershell script 'RestorePoints\Manage-RestorePoints.ps1' that does the following:
1) configures Restore Point Tech to be 'on', for the windows disk, and use at least 8%-10% of the disk space for restore points. If the tech is already 'on', configure to the settings of this script.
2) creates a restore point at specified times, either manually or automatically, once or on a schedule, that can be configured.
3) keeps at least 10 restore points
4) sends an email to a specified address(es) when a restore point is created
5) sends an email to a specified address(es) when a restore point is deleted
6) sends an email to a specified address(es) when a restore point is applied
7) logs all activity to a file, in a configurable location.

Can be part of a scheduled task that runs every 10 minutes. 
has error handling and logging
The script can be triggered by another script as part of a setup for new machines process.

