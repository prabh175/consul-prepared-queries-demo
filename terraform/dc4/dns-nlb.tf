# DNS NLB — forwards port 53 (UDP+TCP) to Consul DNS on port 8600.
#
# Production pattern: hosts set this NLB's EIP as a nameserver in resolv.conf
# (or the org DNS server uses it as a conditional forwarder for the consul sub-zone).
# No dnsmasq or iptables rules needed on individual hosts.
#
# The EIP gives a stable IP that survives NLB node replacement.

resource "aws_eip" "consul_dns_nlb" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-dc4-consul-dns-nlb-eip" }
}

resource "aws_lb" "consul_dns" {
  name               = "${var.project_name}-dc4-dns"
  internal           = false
  load_balancer_type = "network"

  subnet_mapping {
    subnet_id     = aws_subnet.public[0].id
    allocation_id = aws_eip.consul_dns_nlb.id
  }

  tags = { Name = "${var.project_name}-dc4-consul-dns-nlb" }
}

resource "aws_lb_target_group" "consul_dns" {
  name        = "${var.project_name}-dc4-dns"
  port        = 8600
  protocol    = "TCP_UDP"
  target_type = "instance"
  vpc_id      = aws_vpc.this.id

  health_check {
    protocol = "TCP"
    port     = "8500"
    interval = 10
  }
}

resource "aws_lb_target_group_attachment" "consul_dns" {
  target_group_arn = aws_lb_target_group.consul_dns.arn
  target_id        = aws_instance.consul_server.id
}

resource "aws_lb_listener" "consul_dns" {
  load_balancer_arn = aws_lb.consul_dns.arn
  port              = 53
  protocol          = "TCP_UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.consul_dns.arn
  }
}
