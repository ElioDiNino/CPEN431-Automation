# CPEN 431 Automation & Deployment

AWS infrastructure via Terraform for CPEN 431 assignments 7-11 and a script to automate local and remote server/client deployment.

**Author:** [Elio Di Nino](https://github.com/ElioDiNino)

## Disclaimer

Although I have thoroughly tested all of this code, I am not responsible for its use and any costs incurred by running it. Please make sure you understand what the code does before running it.

### Issues & Contributions

If you find any bugs or issues, please open a GitHub issue. I will work to address these promptly. I also accept pull requests if you would like to contribute. Additionally, I will consider feature requests if they are reasonable and generally applicable.

## Features & Overview

### Terraform

> [!IMPORTANT]
> All configurable variables and their defaults are defined in [`variables.tf`](variables.tf) (they are also underlined in the list below). See the Terraform documentation [here](https://developer.hashicorp.com/terraform/language/values/variables#variables-on-the-command-line) for how to set these variables in the command line or in a separate configuration file if you don't want to use the defaults.

- Allows for deployment to the <ins>AWS region of your choice</ins>
- Selects the latest Ubuntu AMI with a <ins>configurable version</ins>
- Creates a security group for the EC2 instances
    - Allows outgoing traffic to all IP addresses
    - Allows SSH access from all IP addresses
    - Allows all incoming traffic from instances in the same security group
    - Allows all incoming UPD and TCP traffic
- Creates a key pair for SSH access which is saved to the local machine as `ec2.pem`
- Creates an EC2 launch template
    - The <ins>instance type is configurable</ins>
    - Defines a <ins>configurable maximum hourly price</ins> per instance
       - This is so that during demand spikes when the price also spikes, the instances will be terminated if the price exceeds the maximum
       - The default should work without issue for most cases, but you can adjust it if needed (e.g. if you are running a very large instance type)
       - A reasonable value is around 1.5x the spot price listed [here](https://aws.amazon.com/ec2/spot/pricing/) (assuming you are not looking at prices during a demand spike)
- Creates an EC2 instance spot fleet with two instances
    - The first instance is arbitrarily chosen to be the server and the second to be the client
- Configures the instances once booted
    - The instructor's public key is added to the `authorized_keys` file
    - Required dependencies are installed (e.g. Java 21)
    - Everything in [`upload/`](upload) is uploaded to the instances
        - You should put your JAR files in this directory
- Tags are added to all resources for easy identification
- Outputs various helpful information including the AMI used, IP addresses, and SSH commands

### Automation Script ([`start.sh`](start.sh))

- Can be run standalone for local use or in combination with the Terraform deployment
- Allows for running the server and client JAR files locally or remotely
- Can deploy multiple servers via a CLI argument
- Handles the synchronization of files to the remote servers and fetching of logs
- For more information, see the [Script Usage](#script-commands) section

## Prerequisites

> [!WARNING]
> If you are using Windows and plan to use the automation script after infrastructure creation with Terraform, you must use Windows Subsystem for Linux (WSL) for everything. If you only want to use the Terraform, you can use the Windows version of the Terraform CLI.

### Terraform

1. Install the [Terraform CLI](https://developer.hashicorp.com/terraform/install)
2. Create an IAM user in the AWS console with the necessary permissions:
    1. Visit https://console.aws.amazon.com/iam/
    2. Click on "Users" in the left-hand menu
    3. Click on "Create user"
    4. Enter a username (e.g. `terraform`) and press "Next"
    5. Select "Attach policies directly" and attach the following policy:
        - `AmazonEC2FullAccess`
    6. Click "Next" and then "Create user"
        - You can add optional tags if you want
    7. Click on the newly created user
    8. Click on the "Security credentials" tab
    9. Click on "Create access key"
    10. Select "Other" and click "Next"
    11. Add an optional description and click "Create access key"
    12. Save the `Access key` and `Secret access key` somewhere safe
    13. Copy the [`.env.example`](.env.example) file to `.env` and fill in the `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` with the values from the previous step

### Automation Script

Make sure you are running the script on a Unix-like system (e.g. Linux, macOS, Windows Subsystem for Linux) with the following installed:
- `bash`
- `ssh`
- `scp`
- [`jq`](https://jqlang.org/)

> [!NOTE]
> If you are using the automation script to interact with AWS EC2 instances, your infrastructure must have been created with the Terraform in this repository first as it creates specific file paths and uses the generated key pair.

## Usage

### Terraform Environment Variables

The following environment variables are required as outlined in the [Terraform Prerequisites](#terraform) section:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

> [!TIP]
> For advanced users, you may use any of the other authentication methods outlined in the AWS Terraform Provider documentation [here](https://registry.terraform.io/providers/hashicorp/aws/latest/docs#authentication-and-configuration). The above configuration is just a simple way to get started for most users.

### Terraform Commands

1. **Load the environment variables**

    This will load the environment variables from the `.env` file. If you are on Windows **and not using the automation script after**, you can use the [`set` command](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/set_1) for each variable manually instead.
    ```bash
    source .env
    ```

2. **Initialize the Terraform configuration**

    This will download dependencies and initialize the project.
    ```bash
    terraform init
    ```

3. **Plan the infrastructure changes**

    This will give you a preview of the changes that will be made. If you make any changes to the configuration or want to test different variables, you should run this command with those changes to see what will happen.
    ```bash
    terraform plan
    ```

4. **Apply the infrastructure changes**

    This will plan then create the infrastructure as defined in the Terraform configuration. You will be prompted to confirm the changes before they are made by typing `yes`.
    ```bash
    terraform apply
    ```

    Once this has successfully completed, you can use the [script detailed below](#script-commands) to deploy your JAR files to the instances and run them.

5. **View the outputs**

    This will show you the outputs defined in the Terraform configuration. This includes the IP addresses of the instances and the SSH commands to connect to them. Note that this information is also outputted after running `terraform apply`, but you can run this command at any time to see it again.
    ```bash
    terraform output
    ```

6. **Destroy the infrastructure**

    This will destroy all the infrastructure created by Terraform. You should do this when you are done with the instances to avoid incurring unnecessary costs.
    ```bash
    terraform destroy
    ```

### Script Commands

> [!WARNING]
> Due to the complex nature of the requirements, this is a more opinionated script (limitations outlined below) and may not work for all use cases. You may need to modify it to suit your needs.

- All JARs being run (local or remote) must be put in the [`upload/`](upload) directory
- Logs will be saved in the [`logs/`](logs) directory
- The script assumes the interface for your **server** and **client** JARs take the following arguments at a minimum:
    - `--servers-list`: The file containing the list of servers
    - For the **server** JAR only:
        - `--index`: The line number (0-indexed) in the above list belonging to the current server
- Things work best if you run the script from the directory containing the script (i.e. the root of this repository), but it will work from anywhere provided the paths are relative to the script location
    - E.g. If you are running in a directory above the script, you should use `./<dir>/start.sh` with `upload/<jar>.jar` for any JAR paths

1. **See all available commands**

    ```bash
    ./start.sh --help
    ```
   > You can also look near the top of [`start.sh`](start.sh) for the help text that is printed.

2. **See the arguments required for a specific command**

    Note that commands that don't take arguments (e.g. `upload`) will run instead of showing the usage information.
    ```bash
    ./start.sh <command>
    ```
