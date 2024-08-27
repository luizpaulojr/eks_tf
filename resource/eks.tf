provider "aws" {
  region = "us-east-1" # Update this to your preferred region
}

module "eks" {
  source                                   = "../terraform-aws-eks-20.24.0"
  cluster_name                             = "eks-cluster"
  cluster_version                          = "1.30"                                                   # Update to your desired Kubernetes version
  vpc_id                                   = "vpc-030eba1ad19d72ea5"                                  # Provide your VPC ID
  control_plane_subnet_ids                 = ["subnet-0363ae174228f5be6", "subnet-07e8f2dba6612aede", "subnet-0677c0ee0cbd3a8e1"]
  cluster_additional_security_group_ids    = ["sg-020b1cd96131a4adc"]
  create_cluster_security_group            = false
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true 

  eks_managed_node_groups = {
    node_group_1 = {
      desired_capacity           = 1
      max_capacity               = 3
      min_capacity               = 1
      instance_types             = ["t3.medium"] # Choose the instance type according to your needs
      subnet_ids                 = ["subnet-0363ae174228f5be6"]
      use_name_prefix            = false
      disk_size                  = 24
      use_custom_launch_template = false
      labels = {
        "role" = "frontend"
        "env"  = "production"
      }
    }
    node_group_2 = {
      desired_capacity = 1
      max_capacity     = 2
      min_capacity     = 1
      instance_types   = ["t3.small"] # Choose the instance type according to your needs
      subnet_ids       = ["subnet-07e8f2dba6612aede"]
      use_name_prefix  = false
      block_device_mappings = [
        {
          device_name = "/dev/xvda" # Root volume
          ebs = {
            volume_size           = 30    # Set the disk size in GB
            volume_type           = "gp3" # General Purpose SSD (GP2)
            delete_on_termination = true
          }
        }
      ]  
    }
    # node_group_3 = {
    #   desired_capacity = 3
    #   max_capacity     = 4
    #   min_capacity     = 2
    #   instance_type    = "t3.small"  # Choose the instance type according to your needs
    #   key_name          = "my-key"  # Provide your key pair name
    #   subnet_ids       = ["subnet-0363ae174228f5be6"]
    #   use_name_prefix  = false
    # }
  }
}

