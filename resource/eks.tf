provider "aws" {
  region = "us-east-1" # Update this to your preferred region
}

locals {
  cluster_name = "eks-cluster" # Update with CLUSTER NAME
}

module "eks" {
  source                                   = "../tf-module-aws-eks"
  cluster_name                             = local.cluster_name
  cluster_version                          = "1.33" # Update to your desired Kubernetes version
  vpc_id                                   = "vpc-0abc1234de5f67890" # Provide your VPC ID
  control_plane_subnet_ids                 = ["subnet-0ab1234cd567890ef", "subnet-0abcd1234ef567890"]
  #cluster_additional_security_group_ids   = ["sg-0abc1234def567890"]
  create_cluster_security_group            = true
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true 
## karpenter ## https://artifacthub.io/packages/helm/aws-karpenter-crd/karpenter-crd
##(Necessário add tag na Subnet"kubernetes.io/role/internal-elb:1", caso nlb privado)
  region                                   = "us-east-1"
  karpenter_enable                         = true
  karpenter_version                        = "1.5.0"
  capacity_type_tools                      = "spot"
  capacity_type_app                        = "on-demand"                        
  disk_size                                = 30
  disk_iops                                = 3000
  subnets_filter_name                      = "general-subnet-private"      # subnets da rede CNI
  sg_filter_name                           = "eks-cluster-node" # sg do node
  node_security_group_tags                 = {
    "karpenter.sh/discovery" = local.cluster_name
  }                       
## Utilizando Karpenter com fargate
  fargate_profiles = [
      {
        name = "karpenter"
        selectors = [
          {
            namespace = "kube-system"
            labels = {
              "app.kubernetes.io/name" = "karpenter"
            }
          }
        ]
      },
      {
        name = "coredns"
        selectors = [
          {
            namespace = "kube-system"
            labels = {
              "k8s-app" = "kube-dns"
            }
          }
        ]
      }
    ]
    subnet_ids = ["subnet-0ab1234cd567890ef", "subnet-0abcd1234ef567890"]
    
##Criação de nodegroup, caso necessário.    
  # eks_managed_node_groups = {
  #   node_group_NAME = {  
  #     ami_type                     = "BOTTLEROCKET_x86_64"
  #     iam_role_additional_policies = {
  #       AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  #     }
  #     desired_size                 = 0
  #     max_size                     = 1
  #     min_size                     = 0
  #     instance_types               = ["t3.small"] # Choose the instance type according to your needs
  #     subnet_ids                   = ["subnet-0363ae174228f5be6", "subnet-07e8f2dba6612aede"]
  #     use_name_prefix              = false
  #     block_device_mappings        = [
  #       {
  #         device_name = "/dev/xvdb" # Root volume
  #         ebs = {
  #           volume_size           = 30    # Set the disk size in GB
  #           volume_type           = "gp3" # General Purpose SSD (GP2)
  #           delete_on_termination = true
  #         }
  #       }
  #     ]  
  #   }
  # }
}

