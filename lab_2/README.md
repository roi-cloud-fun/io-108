# Lab 2: EKS Pod Failure Investigation

| | |
|---|---|
| **Course** | IO-108 Troubleshooting and Incident Simulation |
| **Lab** | Lab 2 — EKS Pod Failure Investigation |
| **Duration** | 45 minutes |
| **Severity** | **P2** (application workload down — pods cannot run) |
| **Difficulty** | Intermediate |
| **Prerequisites** | Lab 0 complete (stack deployed, board readable). Lab 1 recommended. AWS CLI v2, `kubectl`, `jq`. |
| **Builds On** | Lab 0 (the connected application and the incident board) |

---

## Lab Overview

This lab is two layers of EKS troubleshooting on your one application:

1. **Pods unschedulable (the sold incident).** Your `orders` pods are stuck `Pending`. You will read the scheduler's own explanation, trace it to the managed node group, and restore capacity. The **`EKS pods schedulable`** tile drives this half.
2. **Pod connectivity cut (the add-on).** Even with capacity back, the pods cannot reach the internet or resolve DNS — a default-deny **NetworkPolicy** is blocking egress. You will diagnose it from inside a pod and open the necessary egress, learning why the **VPC CNI must have NetworkPolicy enforcement enabled** for the rule to apply at all. The **`Pod → internet`** and **`Pod → DNS`** tiles drive this half.

> **A note on the network layer.** The pod-egress path you investigate here (pod → NAT → internet, pod → CoreDNS) runs over native AWS networking. This lab uses native AWS networking (and AWS Transit Gateway where transit appears). In your environment the hub-and-spoke transit is **Aviatrix**, managed by the network team — the concepts map directly; the management plane differs.

---

## Scenario

Your **`EKS pods schedulable`** tile has gone **red**. The order-processing workload is not running — new `orders-api` and `worker` pods are sitting in `Pending` and the service is effectively down. There was no application deploy; the cluster control plane is healthy and the API server responds.

You open a **P2** incident in **ServiceNow**: the workload is down, but the blast radius is one application in the training account and there is no data loss. Your task is to find why the scheduler cannot place the pods, restore them, and then chase down a second, quieter problem the connectivity probes have surfaced: the pods that *do* run cannot talk to anything outside the cluster.

**To inject this incident** (instructor-led, or self-serve):

```bash
cd lab_environment/lab_env_student
terraform apply -var student_id=$SID -var scenario=lab2
./deploy_app.sh
```
<!-- source: course_outline_v3.md §"Lab 2: EKS Pod Failure Investigation" -->

The `terraform apply` scales your managed node group to **zero**; the `./deploy_app.sh`
re-deploy applies the default-deny egress NetworkPolicy to the `orders` namespace (the policy
is delivered by the Helm chart, so the redeploy is required — terraform alone does not apply
it). Within a minute the three Lab 2 tiles go red. (`deploy_app.sh` will warn that the
`orders-api` rollout did not complete — that is expected with zero nodes; it continues anyway.)

---

## Learning Objectives

By the end of this lab, you will:

- Distinguish pod **status** values (`Pending` vs `Running` vs `CrashLoopBackOff`) and read a `FailedScheduling` event to its root cause.
- Trace a scheduling failure to **node-group capacity** and confirm it with the EKS API and Container Insights.
- Scale a managed node group back up with `aws eks update-nodegroup-config` and watch pods schedule.
- Diagnose pod egress and DNS failures from inside a container using `curl` and `nslookup`.
- Inspect Kubernetes **NetworkPolicies**, understand the **VPC CNI NetworkPolicy enforcement** requirement, and open the needed egress so `Pod → internet` and `Pod → DNS` go green.

---

## Task 1: Triage from the Board

1. **Open** your incident board (**CloudWatch → Dashboards → `io108-$SID-incident-board`**). Confirm the Lab 2 band: **`EKS pods schedulable`** is red, and **`Pod → internet`** and **`Pod → DNS`** are red (these last two stop publishing once pod egress is cut, so they go red on missing data).

2. **Re-establish** your shell context:

    ```bash
    export SID=sNN
    export REGION=us-east-1
    cd lab_environment/lab_env_student
    export CLUSTER=$(terraform output -raw cluster_name)
    aws eks update-kubeconfig --name "$CLUSTER" --region $REGION
    ```
<!-- source: Lab_2_narrative.md §"kubectl Investigation" -->

> **Expected Result:** Three red tiles in the Lab 2 band. Incident logged as P2 in ServiceNow.

---

## Task 2: Read the Pod Status and the Scheduler's Reason

3. **List** the pods in the `orders` namespace:

    ```bash
    kubectl -n orders get pods
    ```
<!-- source: Lab_2_narrative.md §"kubectl get pods" -->

    You will see `orders-api` and `worker` pods in **`Pending`** — and, importantly, they are not `CrashLoopBackOff` or `ImagePullBackOff`. `Pending` means the scheduler has not been able to place the pod on a node at all. The distinction matters: `Pending` is a *placement* problem, not an *application* problem.

4. **Describe** a Pending pod and read its **Events** — the scheduler writes the reason there:

    ```bash
    POD=$(kubectl -n orders get pods -l app=orders-api -o jsonpath='{.items[0].metadata.name}')
    kubectl -n orders describe pod "$POD" | sed -n '/Events:/,$p'
    ```
<!-- source: facts_extracted_v2.md §"kubectl describe pod" -->

5. **Find** the `FailedScheduling` event. It reads along the lines of:

    ```
    Warning  FailedScheduling  default-scheduler
    0/0 nodes are available: no nodes available to schedule pods.
    ```

    or, if nodes are mid-termination:

    ```
    0/2 nodes are available: 2 Insufficient cpu / nodes are being drained.
    ```

> **Expected Result:** The scheduler explicitly reports it has **no nodes** (or insufficient capacity) to place the pods. This points away from the application and toward the cluster's compute capacity.

---

## Task 3: Confirm It Is a Node-Group Capacity Problem

6. **Check** the nodes the cluster can see:

    ```bash
    kubectl get nodes
    ```
<!-- source: Lab_2_narrative.md §"kubectl get nodes" -->

    Expect **`No resources found`** — there are no worker nodes registered.

7. **Confirm** at the source: inspect the managed node group's scaling configuration via the EKS API:

    ```bash
    aws eks describe-nodegroup \
      --cluster-name "$CLUSTER" \
      --nodegroup-name io108-$SID-nodes \
      --region $REGION \
      --query 'nodegroup.scalingConfig'
    ```
<!-- source: facts_extracted_v2.md §"EKS Node Group Issues" -->

    The healthy baseline is `minSize: 2, desiredSize: 2, maxSize: 3`. In this incident you will see **`desiredSize: 0`** (and `minSize: 0`) — the node group has been scaled to zero, so the cluster has no capacity and every pod stays `Pending`.

8. **Cross-check** in **Container Insights** (CloudWatch → Insights → Container Insights, or the `io108-$SID-incident-dashboard` graphs). Node count and node CPU/memory metrics flatline to zero, corroborating that capacity — not the application — is the issue.

> **Expected Result:** You can state the root cause precisely: the managed node group `io108-$SID-nodes` has `desiredSize=0`, so there is nowhere to schedule the workload. Capacity in EKS comes from the node group (or Fargate profiles); the scheduler can only place pods on nodes that actually exist.

---

## Task 4: Restore Node Capacity and Confirm Green

9. **Scale** the node group back to the healthy configuration:

    ```bash
    aws eks update-nodegroup-config \
      --cluster-name "$CLUSTER" \
      --nodegroup-name io108-$SID-nodes \
      --region $REGION \
      --scaling-config minSize=2,maxSize=3,desiredSize=2
    ```
<!-- source: Lab_2_narrative.md §"update-nodegroup-config" -->

10. **Watch** nodes join and pods schedule (node provisioning and the `kubelet` registering takes a few minutes):

    ```bash
    kubectl get nodes -w        # Ctrl-C once 2 nodes are Ready
    kubectl -n orders get pods -w
    ```
<!-- source: Lab_2_narrative.md §"kubectl get nodes" -->

> **Expected Result:** Two nodes reach `Ready`; the `orders-api` and `worker` pods move `Pending → ContainerCreating → Running`. Within a minute of the pods running, the **`EKS pods schedulable`** tile turns **green**. The sold incident's first half is resolved — record the root cause (node group scaled to zero) in ServiceNow.

> **Why fix it with the EKS API instead of `terraform apply`?** Fixing capacity with the EKS API (or console) is the realistic Operations action — it is what an on-call engineer does to restore service immediately, and it is the action the board rewards. Your `update-nodegroup-config` fix holds for the rest of this lab. (Note: because the fault itself is expressed in Terraform as `scenario=lab2`, re-running `terraform apply` while still on `scenario=lab2` would re-inject the fault and scale the group back to zero — so don't re-apply until you move to the next lab/scenario.)

---

## Task 5: Diagnose the Pod Connectivity Failure (Add-On)

With pods running again, the `Pod → internet` and `Pod → DNS` tiles are still red. The in-cluster connectivity checker cannot reach the internet or resolve names — so it stops publishing and its tiles stay red.

11. **Reproduce the egress block from a pod the policy applies to.** The default-deny
    NetworkPolicy selects pods labelled `app.kubernetes.io/part-of: orders` — that includes the
    in-cluster **conncheck** probe whose blocked egress is exactly what turned the
    `Pod → internet` / `Pod → DNS` tiles red. Launch a throwaway pod carrying that label and
    test internet egress. (The `orders-api` app image is `python:3.12-slim` and ships no
    `curl`/`nslookup`, so use Python, which it does have.)

    ```bash
    kubectl -n orders run nettest --rm -i --restart=Never \
      --labels="app.kubernetes.io/part-of=orders" \
      --image=public.ecr.aws/docker/library/python:3.12-slim -- \
      python -c "import socket; socket.setdefaulttimeout(5); socket.create_connection(('example.com',443)); print('reachable')" \
      || echo "egress blocked"
    ```
<!-- source: facts_extracted_v2.md §"Network Troubleshooting" -->

    Expect a timeout / `egress blocked`, not `reachable`. (A debug pod *without* the
    `part-of: orders` label is **not** selected by the policy and would reach the internet
    fine — proof that the block is scoped by the NetworkPolicy's pod selector.)

12. **Test DNS** the same way — resolving a name is itself egress (to CoreDNS in `kube-system`),
    so a blanket egress deny takes DNS out alongside the internet:

    ```bash
    kubectl -n orders run dnstest --rm -i --restart=Never \
      --labels="app.kubernetes.io/part-of=orders" \
      --image=public.ecr.aws/docker/library/python:3.12-slim -- \
      python -c "import socket; print(socket.gethostbyname('example.com'))" \
      || echo "dns blocked"
    ```
<!-- source: facts_extracted_v2.md §"DNS Troubleshooting" -->

    The lookup fails — a pod under the default-deny cannot even reach CoreDNS (`kube-dns`) in `kube-system`.

> **Expected Result:** From inside the pod, both internet egress and DNS resolution fail. The application code is fine; *something at the network-policy layer* is dropping the pod's outbound traffic — including the traffic it needs to reach CoreDNS.

---

## Task 6: Find the NetworkPolicy and the CNI Enforcement Beat

13. **List** the NetworkPolicies in the namespace:

    ```bash
    kubectl -n orders get networkpolicy
    kubectl -n orders describe networkpolicy
    ```
<!-- source: facts_extracted_v2.md §"Network Troubleshooting" -->

    You will find a **default-deny egress** policy: it selects all pods in the namespace and permits no egress, so every outbound packet — internet *and* DNS — is dropped.

14. **Confirm** that enforcement is actually on. A NetworkPolicy is inert unless the CNI enforces it. On EKS, the **VPC CNI must have NetworkPolicy enforcement enabled**, otherwise the AWS CNI silently ignores the policy:

    ```bash
    aws eks describe-addon \
      --cluster-name "$CLUSTER" --addon-name vpc-cni \
      --region $REGION \
      --query 'addon.configurationValues'
    ```
<!-- source: facts_extracted_v2.md §"Network Troubleshooting" -->

    You should see `"enableNetworkPolicy":"true"`. This is the teaching beat: in this environment enforcement **is** on, which is exactly why the default-deny is biting. If enforcement were off, the same policy would exist but have no effect — a classic "the rule looks right but nothing changes" trap.

> **Expected Result:** You can name the cause: a namespace-wide default-deny egress NetworkPolicy, *actively enforced* because the VPC CNI has `enableNetworkPolicy=true`. The fix is not to disable enforcement — it is to allow the egress the workload legitimately needs.

---

## Task 7: Open the Required Egress and Confirm Green

15. **Allow** the egress the pods need: DNS to `kube-system` (UDP/TCP 53) and outbound internet. Apply a targeted allow-egress NetworkPolicy alongside the default-deny (NetworkPolicies are additive — an allow anywhere permits the traffic):

    ```bash
    kubectl apply -f - <<'YAML'
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: orders-allow-egress
      namespace: orders
    spec:
      podSelector: {}
      policyTypes: ["Egress"]
      egress:
        # DNS to CoreDNS in kube-system
        - to:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: kube-system
          ports:
            - { protocol: UDP, port: 53 }
            - { protocol: TCP, port: 53 }
        # Outbound to the internet / AWS APIs (via NAT)
        - to:
            - ipBlock:
                cidr: 0.0.0.0/0
    YAML
    ```
<!-- source: facts_extracted_v2.md §"Network Troubleshooting" -->

    > **Cleaner alternative:** because the default-deny was applied by the Helm chart, you can also re-deploy the application with the policy turned off — `./deploy_app.sh` reads `network_policy_default_deny` from Terraform, so re-applying `scenario=healthy` (or running the deploy with `--set networkPolicy.defaultDeny=false`) removes the default-deny entirely. The targeted allow above is the better *incident-response* habit (restore service with least change); the redeploy is the better *configuration* fix.

16. **Re-test** from a policy-selected pod (same labelled throwaway pod as before):

    ```bash
    kubectl -n orders run nettest --rm -i --restart=Never \
      --labels="app.kubernetes.io/part-of=orders" \
      --image=public.ecr.aws/docker/library/python:3.12-slim -- \
      python -c "import socket; print('dns', socket.gethostbyname('example.com')); socket.setdefaulttimeout(5); socket.create_connection(('example.com',443)); print('egress reachable')"
    ```
<!-- source: facts_extracted_v2.md §"DNS Troubleshooting" -->

> **Expected Result:** DNS resolves and the connection reports `egress reachable`. Within a minute the in-cluster checker publishes again and the **`Pod → internet`** and **`Pod → DNS`** tiles turn **green**. All three Lab 2 tiles are now green — close the P2 incident in ServiceNow with both root causes recorded: node group scaled to zero, and a default-deny egress NetworkPolicy with no allow rule.

---

## Knowledge Check

**Question 1:** A pod is `Pending`; a different pod is `CrashLoopBackOff`. What does each status tell you about *where* the problem is, and which tool gives you the authoritative reason for a `Pending` pod?

**Answer:** `Pending` means the pod has not been **scheduled onto a node** — it is a placement/capacity problem at the cluster level, before the container ever starts. `CrashLoopBackOff` means the pod *was* scheduled and the container started but keeps exiting — an application/runtime problem inside the container. For a `Pending` pod, the authoritative reason is the **`FailedScheduling` event** from `kubectl describe pod` (the scheduler records exactly why it could not place the pod, e.g. "no nodes available" or "Insufficient cpu").

**Question 2:** You restored the node group with `update-nodegroup-config`. Where does scheduling capacity in EKS come from, and why did scaling to zero make *every* pod Pending rather than just some?

**Answer:** Capacity comes from the cluster's **managed node group** (the EC2 worker nodes) — or from Fargate profiles for Fargate pods. With the node group at `desiredSize=0`, there are **no worker nodes at all**, so the scheduler has nowhere to place *any* pod that needs a node — including the application pods and even system pods like CoreDNS. It is not a per-pod resource squeeze; it is a total absence of nodes, which is why the failure is global.

**Question 3:** The default-deny NetworkPolicy existed and was correct, yet on a cluster without VPC CNI NetworkPolicy enforcement it would have had no effect. Explain the dependency, and why DNS broke alongside internet egress.

**Answer:** A Kubernetes NetworkPolicy is only a *declaration* — something must enforce it in the data plane. On EKS the **VPC CNI enforces NetworkPolicies only when `enableNetworkPolicy=true`** is set on the `vpc-cni` addon; otherwise the policy is silently ignored and traffic flows as if it were not there. In this lab enforcement is on, so the **default-deny egress** dropped *all* outbound pod traffic. DNS broke alongside the internet because resolving a name requires the pod to send packets to **CoreDNS in `kube-system`** — that is egress too, so a blanket egress deny takes out name resolution as well as direct internet access. The fix must explicitly allow egress to UDP/TCP 53 toward kube-system.

---

## Lab Summary

You worked a **P2** EKS workload outage from the board to green. Pods stuck `Pending` led you — via the scheduler's own `FailedScheduling` event and the EKS API — to a managed node group scaled to **zero**; `update-nodegroup-config` restored capacity and `EKS pods schedulable` recovered. Then you chased a quieter add-on: pods that could not reach the internet or DNS. From inside a container you proved egress and DNS were blocked, found a **default-deny egress NetworkPolicy**, confirmed the **VPC CNI was enforcing it** (`enableNetworkPolicy=true`), and opened targeted egress — turning `Pod → internet` and `Pod → DNS` green.

## Completion Checklist

- [ ] Lab 2 tiles confirmed red (incident logged as P2 in ServiceNow)
- [ ] Pods observed `Pending`; `FailedScheduling` event read from `kubectl describe`
- [ ] Root cause confirmed: node group `io108-$SID-nodes` at `desiredSize=0` (no nodes registered)
- [ ] Node group scaled to `minSize=2,desiredSize=2,maxSize=3`; pods reach `Running`; `EKS pods schedulable` green
- [ ] Pod egress + DNS failure reproduced from inside a container (`curl` / `nslookup`)
- [ ] Default-deny egress NetworkPolicy found; VPC CNI enforcement (`enableNetworkPolicy=true`) confirmed
- [ ] Targeted egress allowed (or chart redeployed); `Pod → internet` and `Pod → DNS` green

---

## Next Steps

In **Lab 3: Lambda and Step Functions Performance Incident**, the `Reports flowing` tile goes red — the scheduled report workflow is failing under throttling/timeout. You will diagnose the Lambda and Step Functions execution, and meet the event fan-out that distributes alarms to the simulated NewRelic and SolarWinds monitoring sinks.
