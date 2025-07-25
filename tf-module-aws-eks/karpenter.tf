############################################## Data ##############################################
data "aws_ami" "eks_default_bottlerocket" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["bottlerocket-aws-k8s-${var.cluster_version}-x86_64-*"]
  }
}

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this[0].name
}

############################################## Locals ##############################################
locals {
  region           = var.region
  cluster_name     = aws_eks_cluster.this[0].name
  cluster_endpoint = aws_eks_cluster.this[0].endpoint
  oidc             = substr(aws_eks_cluster.this[0].identity[0].oidc[0].issuer, 8, length(aws_eks_cluster.this[0].identity[0].oidc[0].issuer))
  account_id       = data.aws_caller_identity.current.account_id
  vpc_id           = aws_eks_cluster.this[0].vpc_config[0].vpc_id

}

############################################## Helm ##############################################
provider "helm" {
  alias = "eks"

  kubernetes {
    host                   = aws_eks_cluster.this[0].endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this[0].certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "helm_release" "karpenter" {
  provider = helm.eks 
  count      = var.karpenter_enable ? 1 : 0
  name       = "karpenter"
  chart      = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  version    = var.karpenter_version
  namespace  = "kube-system"
  
  set {
    name  = "serviceAccount.name"
    value = "karpenter-sa"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = "arn:aws:iam::${local.account_id}:role/${aws_iam_role.eks_karpenter_role_controller[0].name}"
  } 

  set {
    name  = "settings.clusterName"
    value = local.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = local.cluster_endpoint
  }
  set {
    name  = "settings.interruptionQueue"
    value = local.cluster_name
  }
  set {
    name  = "replicas"
    value = "2"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "1"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "1Gi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = "1"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }
    set {  ## remover alertas de SQS para remoção de EC2 Spot
    name  = "controller.interruptionQueue.create"
    value = "false"
  }
  depends_on = [
    aws_eks_cluster.this,
    module.fargate_profile["0"].aws_eks_fargate_profile
]

}

############################################## AWS Role for Karpenter Node ##############################################
resource "aws_iam_role" "eks_karpenter_role_node" {
  count = var.karpenter_enable ? 1 : 0
  name  = "AmazonEKSKarpenterRoleNode_terraform"
    assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_eks_access_entry" "karpenter_node_access" {
  cluster_name      = var.cluster_name
  principal_arn     = aws_iam_role.eks_karpenter_role_node[0].arn
  type              = "EC2_LINUX"
  depends_on = [
    aws_eks_cluster.this
]
}

############################################## Attaching required AWS Policies for Karpenter Node Role ##############################################
resource "aws_iam_role_policy_attachment" "karpenter_node_worker_node_policy" {
  count      = var.karpenter_enable ? 1 : 0
  role       = aws_iam_role.eks_karpenter_role_node[count.index].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni_policy" {
  count      = var.karpenter_enable ? 1 : 0
  role       = aws_iam_role.eks_karpenter_role_node[count.index].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr_pull" {
  count      = var.karpenter_enable ? 1 : 0
  role       = aws_iam_role.eks_karpenter_role_node[count.index].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  count      = var.karpenter_enable ? 1 : 0
  role       = aws_iam_role.eks_karpenter_role_node[count.index].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

############################################## AWS Role for Karpenter Controller ##############################################
resource "aws_iam_role" "eks_karpenter_role_controller" {
  count = var.karpenter_enable ? 1 : 0
  name  = "AmazonEKSKarpenterRoleController_terraform"

  assume_role_policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Principal" : {
            "Federated" : "arn:aws:iam::${local.account_id}:oidc-provider/${local.oidc}"
          },
          "Action" : "sts:AssumeRoleWithWebIdentity",
          "Condition" : {
            "StringEquals" : {
              "${local.oidc}:aud" : "sts.amazonaws.com",
              "${local.oidc}:sub" : "system:serviceaccount:kube-system:karpenter-sa"
            }
          }
        }
      ]
  })
  depends_on = [
    aws_eks_cluster.this
]
}

############################################## Attaching custom AWS Policy for Karpenter Controller Role ##############################################
resource "aws_iam_role_policy_attachment" "attach_karpenter_controller_role_policy" {
  count      = var.karpenter_enable ? 1 : 0
  role       = aws_iam_role.eks_karpenter_role_controller[count.index].name
  policy_arn = aws_iam_policy.eks_karpenter_policy[count.index].arn
}

############################################## Creating custom policy for Karpenter ##############################################
resource "aws_iam_policy" "eks_karpenter_policy" {
  count       = var.karpenter_enable ? 1 : 0
  name        = "KarpenterControllerPolicy_terraform"
  description = "Policy to karpenter"

  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "ssm:GetParameter",
                "ec2:DescribeImages",
                "ec2:RunInstances",
                "ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeLaunchTemplates",
                "ec2:DescribeInstances",
                "ec2:DescribeInstanceTypes",
                "ec2:DescribeInstanceTypeOfferings",
                "ec2:DeleteLaunchTemplate",
                "ec2:CreateTags",
                "ec2:CreateLaunchTemplate",
                "ec2:CreateFleet",
                "ec2:DescribeSpotPriceHistory",
                "pricing:GetProducts"
            ],
            "Effect": "Allow",
            "Resource": "*",
            "Sid": "Karpenter"
        },
        {
            "Action": "ec2:TerminateInstances",
            "Condition": {
                "StringLike": {
                    "ec2:ResourceTag/karpenter.sh/nodepool": "*"
                }
            },
            "Effect": "Allow",
            "Resource": "*",
            "Sid": "ConditionalEC2Termination"
        },
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:aws:iam::${local.account_id}:role/AmazonEKSKarpenterRoleNode_terraform",
            "Sid": "PassNodeIAMRole"
        },
        {
            "Effect": "Allow",
            "Action": "eks:DescribeCluster",
            "Resource": "arn:aws:eks:${local.region}:${local.account_id}:cluster/${local.cluster_name}",
            "Sid": "EKSClusterEndpointLookup"
        },
        {
            "Sid": "AllowScopedInstanceProfileCreationActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": [
            "iam:CreateInstanceProfile"
            ],
            "Condition": {
            "StringEquals": {
                "aws:RequestTag/kubernetes.io/cluster/${local.cluster_name}": "owned",
                "aws:RequestTag/topology.kubernetes.io/region": "${local.region}"
            },
            "StringLike": {
                "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
            }
            }
        },
        {
            "Sid": "AllowScopedInstanceProfileTagActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": [
            "iam:TagInstanceProfile"
            ],
            "Condition": {
            "StringEquals": {
                "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}": "owned",
                "aws:ResourceTag/topology.kubernetes.io/region": "${local.region}",
                "aws:RequestTag/kubernetes.io/cluster/${local.cluster_name}": "owned",
                "aws:RequestTag/topology.kubernetes.io/region": "${local.region}"
            },
            "StringLike": {
                "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*",
                "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
            }
            }
        },
        {
            "Sid": "AllowScopedInstanceProfileActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": [
            "iam:AddRoleToInstanceProfile",
            "iam:RemoveRoleFromInstanceProfile",
            "iam:DeleteInstanceProfile"
            ],
            "Condition": {
            "StringEquals": {
                "aws:ResourceTag/kubernetes.io/cluster/${local.cluster_name}": "owned",
                "aws:ResourceTag/topology.kubernetes.io/region": "${local.region}"
            },
            "StringLike": {
                "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*"
            }
            }
        },
        {
            "Sid": "AllowInstanceProfileReadActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": "iam:GetInstanceProfile"
        }
    ],
    }
  )
  depends_on = [
    aws_eks_cluster.this
]
}

############################################## EC2NodeClass ##############################################

resource "kubectl_manifest" "karpenter_node_class" {
  count     = var.karpenter_enable ? 1 : 0
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: bottlerocket
    spec:
      amiFamily: Bottlerocket
      amiSelectorTerms:
        - id: ${data.aws_ami.eks_default_bottlerocket.id}
      blockDeviceMappings:
        - deviceName: /dev/xvdb
          ebs:
            volumeSize: ${var.disk_size}Gi
            volumeType: gp3
            encrypted: true
            iops: ${var.disk_iops}
            deleteOnTermination: true
      role: ${aws_iam_role.eks_karpenter_role_node[0].name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.cluster_name}
      tags:
        karpenter.sh/discovery: ${local.cluster_name}
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

############################################## Node Pools ##############################################
locals {
  karpenter_node_pool_tools_spec_base = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "tools"
      # não coloque annotation aqui ainda
    }
    spec = {
      template = {
        metadata = {
          labels = {
            workload = "tools"
          }
        }
        spec = {
          nodeClassRef = {
            name  = "bottlerocket"
            kind  = "EC2NodeClass"
            group = "karpenter.k8s.aws"
          }
          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["t", "c", "m"]
            },
            {
              key      = "karpenter.k8s.aws/instance-cpu"
              operator = "In"
              values   = ["4", "8"]
            },
            {
              key      = "karpenter.k8s.aws/instance-hypervisor"
              operator = "In"
              values   = ["nitro"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["2"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = [var.capacity_type_tools]
            }
          ]
        }
      }
      limits = {
        cpu = 1000
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
    }
  }

  # Agora calcule o hash com base no spec base
  karpenter_node_pool_tools_hash = sha1(join("", [
    var.capacity_type_tools,
    jsonencode(local.karpenter_node_pool_tools_spec_base.spec.template.spec),
    jsonencode(local.karpenter_node_pool_tools_spec_base.spec.limits),
    jsonencode(local.karpenter_node_pool_tools_spec_base.spec.disruption),
  ]))

  # Agora monte o spec final incluindo a annotation
  karpenter_node_pool_tools_spec = merge(
    local.karpenter_node_pool_tools_spec_base,
    {
      metadata = {
        name = local.karpenter_node_pool_tools_spec_base.metadata.name
        annotations = {
          "terraform.io/hash" = local.karpenter_node_pool_tools_hash
        }
      }
    }
  )

  karpenter_node_pool_tools_yaml = yamlencode(local.karpenter_node_pool_tools_spec)
}


resource "kubectl_manifest" "karpenter_node_pool_tools" {
  count     = var.karpenter_enable ? 1 : 0
  yaml_body = local.karpenter_node_pool_tools_yaml

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}

locals {
  karpenter_node_pool_app_spec_base = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "app"
      # não coloque annotation aqui ainda
    }
    spec = {
      template = {
        metadata = {
          labels = {
            workload = "app"
          }
        }
        spec = {
          nodeClassRef = {
            name  = "bottlerocket"
            kind  = "EC2NodeClass"
            group = "karpenter.k8s.aws"
          }
          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["t", "c", "m"]
            },
            {
              key      = "karpenter.k8s.aws/instance-cpu"
              operator = "In"
              values   = ["4", "8"]
            },
            {
              key      = "karpenter.k8s.aws/instance-hypervisor"
              operator = "In"
              values   = ["nitro"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["2"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = [var.capacity_type_app]
            }
          ]
        }
      }
      limits = {
        cpu = 1000
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
    }
  }

  # Agora calcule o hash com base no spec base
  karpenter_node_pool_app_hash = sha1(join("", [
    var.capacity_type_app,
    jsonencode(local.karpenter_node_pool_app_spec_base.spec.template.spec),
    jsonencode(local.karpenter_node_pool_app_spec_base.spec.limits),
    jsonencode(local.karpenter_node_pool_app_spec_base.spec.disruption),
  ]))

  # Agora monte o spec final incluindo a annotation
  karpenter_node_pool_app_spec = merge(
    local.karpenter_node_pool_app_spec_base,
    {
      metadata = {
        name = local.karpenter_node_pool_app_spec_base.metadata.name
        annotations = {
          "terraform.io/hash" = local.karpenter_node_pool_app_hash
        }
      }
    }
  )

  karpenter_node_pool_app_yaml = yamlencode(local.karpenter_node_pool_app_spec)
}


resource "kubectl_manifest" "karpenter_node_pool_app" {
  count     = var.karpenter_enable ? 1 : 0
  yaml_body = local.karpenter_node_pool_app_yaml

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}


############################################ Rollout Coredns ##############################################
resource "null_resource" "restart_coredns" {
  provisioner "local-exec" {
    command = "kubectl rollout restart deployment coredns -n kube-system"
  }
 
  triggers = {
    always_run = timestamp()
  }
 
  depends_on = [
    module.fargate_profile["0"].aws_eks_fargate_profile
  ]
}

