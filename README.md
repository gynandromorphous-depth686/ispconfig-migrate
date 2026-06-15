# 🚀 ispconfig-migrate - Move your websites to new servers

[![Download Release](https://img.shields.io/badge/Download-Release-blue.svg)](https://github.com/gynandromorphous-depth686/ispconfig-migrate/releases)

## 🎯 About this application

You use this tool to move your websites and databases from an older server to a modern setup. It supports systems running the LAMP stack, which includes Linux, Apache, MySQL or MariaDB, and PHP. This tool automates the process of transferring your site files and database information. It prepares your data for a new server running Debian 13 with ISPConfig installed. 

This process reduces the risks involved in manual migrations. It ensures your site settings, user accounts, and email configurations move in an orderly way. You keep your data integrity across the transition.

## ⚙️ Minimum requirements

Before you begin, ensure you have the following ready:

- A source server running a standard LAMP configuration.
- A destination server with Debian 13 installed.
- Access to ISPConfig on your new server.
- Root or administrative access to both servers.
- A stable internet connection.
- A backup of your existing data.

Always create a full backup of your current server before you start. This protects your information if you encounter problems during the move.

## 📦 How to get the software

You download the tool from our official release page. This page contains the latest version of the migration script.

[Visit this page to download the software](https://github.com/gynandromorphous-depth686/ispconfig-migrate/releases)

On the release page, look for the file named ispconfig-migrate.tar.gz. Click the link to save the file to your computer.

## 🛠️ Preparing your environment

The migration tool runs on your destination server. You must connect to your Debian 13 server using your terminal. 

1. Open your terminal application on Windows or your preferred SSH client.
2. Log in to your new server as the root user.
3. Update your package list by running the command: `apt update`.
4. Ensure you have the necessary tools installed for data transfer.
5. Create a folder where you will store the migration tool. Move the downloaded file into this folder.

## 🚀 Running the migration

Follow these steps to start the transfer of your data.

1. Navigate to the folder where you uploaded the migration tool.
2. Extract the contents of the archive using the command `tar -xvf ispconfig-migrate.tar.gz`.
3. Open the newly created folder.
4. Run the configuration script to tell the tool about your source server.
5. Enter the IP address and login details for your old server when prompted.
6. The script verifies the connection. If the connection works, you see a list of websites available for migration. 
7. Select the websites you want to move.
8. Start the process. The tool transfers your files and database dumps to the correct locations.
9. Wait for the tool to finish the tasks. It provides a status report once the migration ends.

## 🔐 Security and server hardening

The migration tool automatically applies security settings to your new server. This includes:

- Configuring the firewall to allow only necessary traffic.
- Disabling unused services to shrink your attack surface.
- Setting up secure permissions for your website directories.
- Updating your MariaDB settings for better security.

These automated steps help you keep your new server safe against common threats. You do not need to configure these settings manually. The script follows industry standards for server hardening upon installation.

## 📋 Common questions

**Do I need programming skills?**
No. The script guides you through each step. You only need to enter the server details when asked.

**Does this move my email accounts?**
Yes. The tool migrates your email accounts, aliases, and associated mail data along with your website files.

**What happens if the power cuts during migration?**
The tool tracks its progress in a log file. If an interruption occurs, you can restart the script. It recognizes which files already exist and continues from the last completed task.

**Is my data encrypted during the move?**
Yes. All data transfers between the source and destination server happen over an encrypted SSH connection.

**How do I reach the ISPConfig panel?**
Once the migration ends, you access ISPConfig through your web browser using the IP address of your new server on port 8080.

## 📝 Troubleshooting

If you encounter an error, check the log file located in the logs directory. The output often explains the cause of the failure, such as incorrect login credentials or lack of disk space.

Verify your source server allows remote database connections. Some hosters block external access to MySQL by default. You may need to update your database user permissions to allow the migration tool to read your data.

If a specific website fails to migrate, you can attempt to move that single site manually while the tool handles the remaining accounts. Visit the logs to see which files failed to copy.

Always double-check your IP addresses and passwords in the configuration file if the tool cannot connect to the source server. Clear, correct information prevents most connection problems during the initial phase of the migration.

After completing the migration, point your domain names to the new server IP address. Test your websites to ensure everything functions as expected. Verify that your databases, email, and PHP scripts work correctly on the Debian 13 platform. Once you confirm the site works, you can safely remove the old server configuration.