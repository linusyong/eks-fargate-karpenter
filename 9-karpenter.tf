#
# IAM Role
#
resource "aws_iam_role" "karpenter" {
  description        = "IAM Role for Karpenter Controller (pod) to assume"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role.json
  name               = "${var.cluster_name}-karpenter-controller"
  inline_policy {
    policy = data.aws_iam_policy_document.karpenter.json
    name   = "karpenter"
  }
}

#
# IRSA policy
#
data "aws_iam_policy_document" "karpenter_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      values   = ["system:serviceaccount:karpenter:karpenter"]
      variable = "${var.cluster_oidc_url}:sub"
    }
    condition {
      test     = "StringEquals"
      values   = ["sts.amazonaws.com"]
      variable = "${var.cluster_oidc_url}:aud"
    }
    principals {
      type        = "Federated"
      identifiers = [var.cluster_oidc_arn]
    }
  }
}

#
# Inline policy
#
data "aws_iam_policy_document" "karpenter" {
  statement {
    resources = ["*"]
    actions   = ["ec2:DescribeImages", "ec2:RunInstances", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeLaunchTemplates", "ec2:DescribeInstances", "ec2:DescribeInstanceTypes", "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeAvailabilityZones", "ec2:DeleteLaunchTemplate", "ec2:CreateTags", "ec2:CreateLaunchTemplate", "ec2:CreateFleet", "ec2:DescribeSpotPriceHistory", "pricing:GetProducts", "ssm:GetParameter"]
    effect    = "Allow"
  }
  statement {
    resources = ["*"]
    actions   = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
    effect    = "Allow"
    # Make sure Karpenter can only delete nodes that it has provisioned
    condition {
      test     = "StringEquals"
      values   = [var.cluster_name]
      variable = "ec2:ResourceTag/karpenter.sh/discovery"
    }
  }
  statement {
    resources = [var.cluster_arn]
    actions   = ["eks:DescribeCluster"]
    effect    = "Allow"
  }
  statement {
    resources = [aws_iam_role.eks_node.arn]
    actions   = ["iam:PassRole"]
    effect    = "Allow"
  }
  # Optional: Interrupt Termination Queue permissions, provided by AWS SQS
  statement {
    resources = [aws_sqs_queue.karpenter.arn]
    actions   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes", "sqs:ReceiveMessage"]
    effect    = "Allow"
  }
}

#
# Fargate profile
#
resource "aws_eks_fargate_profile" "karpenter" {
  subnet_ids             = var.cluster_subnet_ids
  cluster_name           = var.cluster_name
  fargate_profile_name   = "karpenter"
  pod_execution_role_arn = aws_iam_role.fargate.arn
  selector {
    namespace = "karpenter"
  }
}

#
# IAM Role
#
resource "aws_iam_role" "fargate" {
  description        = "IAM Role for Fargate profile to run Karpenter pods"
  assume_role_policy = data.aws_iam_policy_document.fargate.json
  name               = "${var.cluster_name}-karpenter-fargate"
}

#
# Assume role policy document
#
data "aws_iam_policy_document" "fargate" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks-fargate-pods.amazonaws.com"]
    }
  }
}

#
# Role attachments
#
resource "aws_iam_role_policy_attachment" "fargate_attach_podexecution" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.fargate.name
}

resource "aws_iam_role_policy_attachment" "fargate_attach_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.fargate.name
}

#
# Instance profile
#
resource "aws_iam_instance_profile" "karpenter" {
  role = aws_iam_role.eks_node.name
  name = "${var.cluster_name}-karpenter-instance-profile"
}

#
# IAM Role
#
resource "aws_iam_role" "eks_node" {
  description        = "IAM Role for Karpenter's InstanceProfile to use when launching nodes"
  assume_role_policy = data.aws_iam_policy_document.eks_node.json
  name               = "${var.cluster_name}-karpenter-node"
}

#
# Policy attachments
#
resource "aws_iam_role_policy_attachment" "eks_node_attach_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_node_attach_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_node_attach_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node.name
}

resource "aws_iam_role_policy_attachment" "eks_node_attach_AmazonSSMManagedInstanceCore" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.eks_node.name
}

#
# SQS Queue
#
resource "aws_sqs_queue" "karpenter" {
  message_retention_seconds = 300
  name                      = "${var.cluster_name}-karpenter"
}

#
# Node termination queue policy
#
resource "aws_sqs_queue_policy" "karpenter" {
  policy    = data.aws_iam_policy_document.node_termination_queue.json
  queue_url = aws_sqs_queue.karpenter.url
}

data "aws_iam_policy_document" "node_termination_queue" {
  statement {
    resources = [aws_sqs_queue.karpenter.arn]
    sid       = "SQSWrite"
    actions   = ["sqs:SendMessage"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

# KARPENTER_VERSION="v0.25.0"

# CLUSTER_NAME=...                  # Name of the EKS Cluster
# CLUSTER_ENDPOINT=...              # Endpoint for the EKS Cluster
# KARPENTER_IAM_ROLE_ARN=...        # IAM Role ARN for the Karpenter Controller
# KARPENTER_INSTANCE_PROFILE=...    # InstanceProfile name for Karpenter nodes
# KARPENTER_QUEUE_NAME=...          # Name of the SQS queue for Karpenter

# helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter 
#   --version "${KARPENTER_VERSION}" 
#   --namespace karpenter 
#   --create-namespace 
#   --include-crds 
#   --set settings.aws.clusterName=${CLUSTER_NAME} 
#   --set settings.aws.clusterEndpoint=${CLUSTER_ENDPOINT}
#   --set serviceAccount.annotations."eks.amazonaws.com/role-arn"=${KARPENTER_IAM_ROLE_ARN} 
#   --set settings.aws.defaultInstanceProfile=${KARPENTER_INSTANCE_PROFILE} 
#   --set settings.aws.interruptionQueueName=${KARPENTER_QUEUE_NAME} # Optional