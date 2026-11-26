# Lab 2: EKS Pod Failure Investigation

| | |
|---|---|
| **Course** | IO-108 Troubleshooting and Incident Simulation |
| **Lab** | Lab 2 — EKS Pod Failure Investigation |
| **Duration** | 45 minutes |
| **Severity** | **P2** (application workload down — pods cannot run) |
| **Difficulty** | Intermediate |
| **Prerequisites** | Lab 0 complete (stack deployed, board readable). Lab 1 **Start Here** done on your lab host (it saves `SID`/`REGION` and connects Terraform and `kubectl`); the rest of Lab 1 recommended. Every command runs on the lab host as `ec2-user`. |
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

---

## Learning Objectives

By the end of this lab, you will:

- Distinguish pod **status** values (`Pending` vs `Running` vs `CrashLoopBackOff`) and read a `FailedScheduling` event to its root cause.
- Trace a scheduling failure to **node-group capacity** and confirm it with the EKS API and Container Insights.
- Scale a managed node group back up with `aws eks update-nodegroup-config` and watch pods schedule.
- Diagnose pod egress and DNS failures from inside a container using short Python socket tests.
- Inspect Kubernetes **NetworkPolicies**, understand the **VPC CNI NetworkPolicy enforcement** requirement, and open the needed egress so `Pod → internet` and `Pod → DNS` go green.

---

## Task 1: Lab Setup

Run every command in this lab on your **lab host** as **`ec2-user`** (Session Manager, then `sudo su - ec2-user`, as in Lab 1 Start Here). Run each code block on its own, and wait for it to finish before you start the next.

1. **Go to** the lab directory and **check** your variables:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    echo "SID=$SID REGION=$REGION"
    ```

    The `echo` must show your own id and region, for example `SID=user01 REGION=us-east-1` (not blank, not `userNN`). If it is blank, run `source ~/.bashrc` and run this block again; if it is still wrong, redo Lab 1 Start Here step 3.

2. **Preview** the incident. This command changes nothing; it only shows what the apply will do. Run it on its own:

    ```bash
    terraform plan -var scenario=lab2
    ```

    It takes about a minute and ends with a `Plan:` line. **Check it.** It should be small: about **`Plan: 0 to add, 2 to change, 1 to destroy.`** (2–3 to change, 0–1 to add or destroy). The resources listed above the `Plan:` line are `aws_eks_node_group.main` (scaled to zero), `aws_cloudwatch_dashboard.incident_board` (the board's scenario label), possibly the orders-api IAM policy you repaired in Lab 1, and `aws_ec2_instance_state.rogue[0]` destroyed (this only drops Terraform's record of the rogue's run state; the rogue stays as you left it).

    If it wants to add dozens or 100+ resources, **stop** and tell your instructor; do not run step 3. Terraform cannot see your stack.

3. **Inject** this lab's incident. Run this command on its own:

    ```bash
    terraform apply -var scenario=lab2
    ```
<!-- source: course_outline_v3.md §"Lab 2: EKS Pod Failure Investigation" -->

    Terraform prints the same plan again and stops at a confirmation prompt:

    ```
    Plan: 0 to add, 2 to change, 1 to destroy.

    Do you want to perform these actions?
      Terraform will perform the actions described above.
      Only 'yes' will be accepted to approve.

      Enter a value:
    ```

    - **If the `Plan:` line matches your preview in step 2,** type **`yes`** and press **Enter**. Terraform will not continue until you do, and anything other than `yes` cancels.
    - **If it differs,** type **`no`** and press **Enter**, then tell your instructor.

    > **Expected Result:** After a few minutes (the node group has to scale down), Terraform prints **`Apply complete! Resources: 0 added, 2 changed, 1 destroyed.`** (your numbers may differ by one, as above) followed by a list of outputs, and you are back at the `$` prompt.

4. **Redeploy** the application, so the Helm chart (the package that installs the app on the cluster) applies the default-deny egress NetworkPolicy. Terraform alone does not apply it. Run this only after step 3 has finished:

    ```bash
    ./deploy_app.sh
    ```

    This takes about **5–6 minutes**, and most of that time it looks stuck. It prints `netpol default-deny: true` near the top, then sits on `Waiting for deployment "orders-api" rollout to finish: 0 of 2 updated replicas are available...` for up to 5 minutes, because there are no nodes to run the pods. **Do not press Ctrl+C.**

    > **Expected Result:** The script ends with `WARNING: orders-api is not Ready. For scenario='lab2' this may be EXPECTED (the injected fault).` and then **`Deploy complete.`** That warning is the incident, not an error in the script. (If the old nodes were still draining, the rollout may finish instead; that is also fine.)

5. **Capture** the values this lab uses into shell variables. **After any reconnect, run steps 1 and 5 again**, because a new session forgets these variables:

    ```bash
    cd ~/io-108/lab_environment/lab_env_student
    export CLUSTER=$(terraform output -raw cluster_name)
    echo "CLUSTER=$CLUSTER"
    aws eks update-kubeconfig --name "$CLUSTER" --region $REGION
    ```
<!-- source: Lab_2_narrative.md §"kubectl Investigation" -->

    > **Expected Result:** `CLUSTER=io108-<your-id>-eks`, then one line, `Updated context arn:aws:eks:...:cluster/io108-<your-id>-eks in /home/ec2-user/.kube/config` (or `Added new context ...`). If `CLUSTER=` is blank, or you see `No outputs found`, you are not in the lab directory or Terraform is not connected to your stack: run step 1 again, then this step; if it is still blank, redo Lab 1 Start Here steps 4–5.

On the board, `EKS pods schedulable` goes red within about two minutes of the apply. `Pod → internet` and `Pod → DNS` follow in about 5–8 minutes; they turn red on missing data.

> **Reconnecting later?** Start a new session, run `sudo su - ec2-user`, then run **steps 1 and 5** again. If you were in the middle of Task 3, also re-run the `POD=` line in step 8.

---

## Task 2: Triage from the Board

6. **Open** your incident board. In the AWS console search bar, type **CloudWatch** and open it. Check that the region selector at the top right matches your `REGION`. In the left menu choose **Dashboards**, then open **`io108-<your-id>-incident-board`** (for example `io108-user01-incident-board`). Confirm the Lab 2 band: **`EKS pods schedulable`** is red, and **`Pod → internet`** and **`Pod → DNS`** are red. The last two stop publishing once pod egress is cut, so they go red on missing data. Click the refresh icon (circular arrow) at the top right if the tiles look stale.

> **Expected Result:** Three red tiles in the Lab 2 band. Record the incident as P2 in your incident notes (in production you would open it in ServiceNow).

---

## Task 3: Read the Pod Status and the Scheduler's Reason

7. **List** the pods in the `orders` namespace:

    ```bash
    kubectl -n orders get pods
    ```
    <!-- source: Lab_2_narrative.md §"kubectl get pods" -->

    You will see output like this (names and ages differ):

    ```
    NAME                             READY   STATUS    RESTARTS   AGE
    orders-api-6d9c7b8f5d-4xkqz      0/1     Pending   0          3m
    orders-api-6d9c7b8f5d-p7r2m      0/1     Pending   0          3m
    orders-conncheck-29012345-abcde  0/1     Pending   0          40s
    orders-worker-5f8b9c6d7-k2lmn    0/1     Pending   0          3m
    ```

    The `orders-api-...` and `orders-worker-...` pods are in **`Pending`**. (`orders-conncheck-...` pods belong to the connectivity checker, a job that runs every minute; you will meet it in Task 6.) Importantly, they are not `CrashLoopBackOff` or `ImagePullBackOff`. `Pending` means the scheduler has not been able to place the pod on a node at all. The distinction matters: `Pending` is a *placement* problem, not an *application* problem. (Pods still `Running`? The nodes have not started draining yet: wait 1–2 minutes before step 8, and do not move on to the fix.)

8. **Describe** a Pending pod and read its **Events** — the scheduler writes the reason there:

    ```bash
    POD=$(kubectl -n orders get pods -l app=orders-api --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
    echo "POD=$POD"
    kubectl -n orders describe pod "$POD" | sed -n '/Events:/,$p'
    ```
<!-- source: facts_extracted_v2.md §"kubectl describe pod" -->

    **Verify** `echo` prints a pod name such as `POD=orders-api-6d9c7b8f5d-4xkqz`. If it prints `POD=` with nothing after it (and the next command fails with `resource name may not be empty`), no pod is `Pending` yet: wait 1–2 minutes and re-run this block.

9. **Find** the `FailedScheduling` event. It reads along the lines of:

    ```
    Warning  FailedScheduling  default-scheduler
    0/0 nodes are available: no nodes available to schedule pods.
    ```

    or, if nodes are mid-termination:

    ```
    0/2 nodes are available: 2 node(s) were unschedulable.
    ```

> **Expected Result:** The scheduler explicitly reports it has **no nodes** (or insufficient capacity) to place the pods. This points away from the application and toward the cluster's compute capacity.

---

## Task 4: Confirm It Is a Node-Group Capacity Problem

10. **Check** the nodes the cluster can see:

    ```bash
    kubectl get nodes
    ```
    <!-- source: Lab_2_narrative.md §"kubectl get nodes" -->

    Expect **`No resources found`** — there are no worker nodes registered. (Nodes still draining show `Ready,SchedulingDisabled` for up to ~15 minutes; that already means no capacity, so you can continue.)

11. **Confirm** at the source: inspect the managed node group's scaling configuration via the EKS API:

    ```bash
    aws eks describe-nodegroup \
      --cluster-name "$CLUSTER" \
      --nodegroup-name io108-$SID-nodes \
      --region $REGION \
      --query 'nodegroup.scalingConfig'
    ```
    <!-- source: facts_extracted_v2.md §"EKS Node Group Issues" -->

    In this incident you will see:

    ```
    {
        "minSize": 0,
        "maxSize": 3,
        "desiredSize": 0
    }
    ```

    The healthy baseline is `minSize: 2, desiredSize: 2, maxSize: 3`. Here **`desiredSize` is `0`** (and `minSize` is `0`): the node group has been scaled to zero, so the cluster has no capacity and every pod stays `Pending`. If you get `ResourceNotFoundException`, `SID` or `REGION` is wrong: re-run step 5.

12. **Cross-check** in **Container Insights** (the CloudWatch metrics for your cluster). In the CloudWatch console, choose **Dashboards** and open **`io108-<your-id>-incident-dashboard`** (the graphs dashboard, not the incident board). On the **EKS Node CPU (Container Insights)** graph, the line stops and shows no data from the time the nodes left, corroborating that capacity — not the application — is the issue.

> **Expected Result:** You can state the root cause precisely: the managed node group `io108-<your-id>-nodes` has `desiredSize=0`, so there is nowhere to schedule the workload. Capacity in EKS comes from the node group (or Fargate profiles); the scheduler can only place pods on nodes that actually exist.

---

## Task 5: Restore Node Capacity and Confirm Green

13. **Scale** the node group back to the healthy configuration:

    ```bash
    aws eks update-nodegroup-config \
      --cluster-name "$CLUSTER" \
      --nodegroup-name io108-$SID-nodes \
      --region $REGION \
      --scaling-config minSize=2,maxSize=3,desiredSize=2
    ```
<!-- source: Lab_2_narrative.md §"update-nodegroup-config" -->

    It prints a JSON `update` block containing `"status": "InProgress"` and `"type": "ConfigUpdate"`. That means AWS accepted the change. If you get `ResourceInUseException`, an earlier update is still running: wait 1 minute and re-run the command.

14. **Watch** the nodes join. New EC2 nodes take about **3–5 minutes** to boot and register. This command keeps running and prints a new line each time a node changes:

    ```bash
    kubectl get nodes -w
    ```
<!-- source: Lab_2_narrative.md §"kubectl get nodes" -->

    At first it may print `No resources found` and then nothing for a while; that is normal. Once **two** lines show `STATUS` **`Ready`**, press **Ctrl+C** to stop watching and get your `$` prompt back.

    Then watch the pods schedule:

    ```bash
    kubectl -n orders get pods -w
    ```

    The `orders-api-...` and `orders-worker-...` pods move `Pending → ContainerCreating → Running`, then reach `READY 1/1` about a minute later (the app installs its Python packages at startup). Once they all show `1/1   Running`, press **Ctrl+C**. `orders-conncheck-...` pods that end in `Error` (or sit `Running` for up to 2 minutes first) are expected; they cannot reach the internet to install their packages, and that is the second problem, which you will fix in Tasks 5–7.

> **Expected Result:** Two nodes `Ready`; the `orders-api` and `orders-worker` pods `1/1 Running`. The **`EKS pods schedulable`** tile turns **green** within about a minute of step 13 (it reads the node group's desired size, so it can go green before the pods finish starting). The sold incident's first half is resolved — record the root cause (node group scaled to zero) in ServiceNow. If no node is `Ready` after 10 minutes, re-run step 11 and check that `desiredSize` is `2`.

> **Why fix it with the EKS API instead of `terraform apply`?** Fixing capacity with the EKS API (or console) is the realistic Operations action — it is what an on-call engineer does to restore service immediately, and it is the action the board rewards. Your `update-nodegroup-config` fix holds for the rest of this lab. (Note: because the fault itself is expressed in Terraform as `scenario=lab2`, re-running `terraform apply` while still on `scenario=lab2` would re-inject the fault and scale the group back to zero — so don't re-apply until you move to the next lab/scenario.)

---

## Task 6: Diagnose the Pod Connectivity Failure (Add-On)

With pods running again, the `Pod → internet` and `Pod → DNS` tiles are still red. The in-cluster connectivity checker cannot reach the internet or resolve names — so it stops publishing and its tiles stay red.

15. **Reproduce the egress block from a pod the policy applies to.** The default-deny
    NetworkPolicy selects pods labelled `app.kubernetes.io/part-of: orders` — that includes the
    in-cluster **conncheck** probe whose blocked egress is exactly what turned the
    `Pod → internet` / `Pod → DNS` tiles red. Launch a throwaway pod carrying that label and
    test internet egress. (The `orders-api` app image is `python:3.12-slim` and ships no
    `curl`/`nslookup`, so use Python, which it does have.) The test connects to a public IP
    address (`1.1.1.1`, port 443) rather than a name, so a DNS failure cannot hide the result —
    you test DNS separately in step 16.

    ```bash
    kubectl -n orders run nettest --rm -i --restart=Never \
      --labels="app.kubernetes.io/part-of=orders" \
      --image=public.ecr.aws/docker/library/python:3.12-slim -- \
      python -c "import socket,time; time.sleep(15); socket.setdefaulttimeout(5); socket.create_connection(('1.1.1.1',443)); print('reachable')" \
      || echo "egress blocked"
    ```
    <!-- source: facts_extracted_v2.md §"Network Troubleshooting" -->

    This takes about 30–60 seconds (image download, the 15-second wait, then a 5-second
    timeout). kubectl may print `If you don't see a command prompt, try pressing enter.` —
    ignore it and wait. The 15-second wait matters: the VPC CNI attaches policy a moment
    *after* a pod starts, so an immediate test can slip through.

    > **Expected Result:** A short Python traceback ending in **`TimeoutError: timed out`**,
    > then kubectl's lines about pod `nettest` being deleted / terminated (Error), and finally
    > **`egress blocked`** — not `reachable`. If you see `pods "nettest" already exists`, an
    > earlier run was interrupted: run `kubectl -n orders delete pod nettest` and try again.

    (A debug pod *without* the `part-of: orders` label is **not** selected by the policy and
    would reach the internet fine — proof that the block is scoped by the NetworkPolicy's pod
    selector.)

16. **Test DNS** the same way — resolving a name is itself egress (to CoreDNS in `kube-system`),
    so a blanket egress deny takes DNS out alongside the internet:

    ```bash
    kubectl -n orders run dnstest --rm -i --restart=Never \
      --labels="app.kubernetes.io/part-of=orders" \
      --image=public.ecr.aws/docker/library/python:3.12-slim -- \
      python -c "import socket,time; time.sleep(15); print(socket.gethostbyname('example.com'))" \
      || echo "dns blocked"
    ```
    <!-- source: facts_extracted_v2.md §"DNS Troubleshooting" -->

    This one can take **1–2 minutes**: the resolver retries several times before giving up. Expect a traceback ending in **`socket.gaierror: [Errno -3] Temporary failure in name resolution`**, then **`dns blocked`**. The lookup fails — a pod under the default-deny cannot even reach CoreDNS (`kube-dns`) in `kube-system`. (`pods "dnstest" already exists`? Run `kubectl -n orders delete pod dnstest` and retry.)

> **Expected Result:** From inside the pod, both internet egress and DNS resolution fail. The application code is fine; *something at the network-policy layer* is dropping the pod's outbound traffic — including the traffic it needs to reach CoreDNS.

---

## Task 7: Find the NetworkPolicy and the CNI Enforcement Beat

17. **List** the NetworkPolicies in the namespace:

    ```bash
    kubectl -n orders get networkpolicy
    kubectl -n orders describe networkpolicy
    ```
    <!-- source: facts_extracted_v2.md §"Network Troubleshooting" -->

    The first command lists `orders-default-deny-egress`. You will find a **default-deny egress** policy: it selects the pods labelled `app.kubernetes.io/part-of: orders` and permits them no egress, so every outbound packet from those pods — internet *and* DNS — is dropped.

18. **Confirm** that enforcement is actually on. A NetworkPolicy is inert unless the CNI enforces it. On EKS, the **VPC CNI must have NetworkPolicy enforcement enabled**, otherwise the AWS CNI silently ignores the policy:

    ```bash
    aws eks describe-addon \
      --cluster-name "$CLUSTER" --addon-name vpc-cni \
      --region $REGION \
      --query 'addon.configurationValues' --output text
    ```
    <!-- source: facts_extracted_v2.md §"Network Troubleshooting" -->

    You should see `{"enableNetworkPolicy":"true"}`. This is the teaching beat: in this environment enforcement **is** on, which is exactly why the default-deny is biting. If enforcement were off, the same policy would exist but have no effect — a classic "the rule looks right but nothing changes" trap.

> **Expected Result:** You can name the cause: a default-deny egress NetworkPolicy on the `part-of: orders` pods, *actively enforced* because the VPC CNI has `enableNetworkPolicy=true`. The fix is not to disable enforcement — it is to allow the egress the workload legitimately needs.

---

## Task 8: Open the Required Egress and Confirm Green

19. **Allow** the egress the pods need: DNS to `kube-system` (UDP/TCP 53) and outbound internet. Apply a targeted allow-egress NetworkPolicy alongside the default-deny (NetworkPolicies are additive — an allow anywhere permits the traffic):

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

    Copy the whole block, including the final `YAML` line, and paste it in one go.

    > **Expected Result:** One line: **`networkpolicy.networking.k8s.io/orders-allow-egress created`**. If you see `error: error parsing` or the prompt changes to `>` and waits, the paste was incomplete: press **Ctrl+C** and paste the whole block again.

    > **Cleaner alternative:** because the default-deny was applied by the Helm chart, you can also re-deploy the application with the policy turned off. `./deploy_app.sh` always takes the policy setting from Terraform's `network_policy_default_deny` output (it accepts no `--set` options), so you would run `terraform apply -var scenario=healthy` and then `./deploy_app.sh`. Note that this also scales the node group from Terraform and restarts the rogue instance from Lab 1. The targeted allow above is the better *incident-response* habit (restore service with least change); the redeploy is the better *configuration* fix.

20. **Re-test** from a policy-selected pod (same labelled throwaway pod as before). The first line clears any leftover test pod from an interrupted run:

    ```bash
    kubectl -n orders delete pod nettest dnstest --ignore-not-found
    kubectl -n orders run nettest --rm -i --restart=Never \
      --labels="app.kubernetes.io/part-of=orders" \
      --image=public.ecr.aws/docker/library/python:3.12-slim -- \
      python -c "import socket,time; time.sleep(15); print('dns', socket.gethostbyname('example.com')); socket.setdefaulttimeout(5); socket.create_connection(('example.com',443)); print('egress reachable')"
    ```
<!-- source: facts_extracted_v2.md §"DNS Troubleshooting" -->

    After about 20–30 seconds it prints two lines: `dns` followed by an IP address (for example `dns 23.192.228.80`; the address varies), then `egress reachable`.

> **Expected Result:** DNS resolves and the connection reports `egress reachable`. If it still fails, run `kubectl -n orders get networkpolicy` and check that `orders-allow-egress` is listed; if not, repeat step 19. Within 1–2 minutes the in-cluster checker publishes again and the **`Pod → internet`** and **`Pod → DNS`** tiles turn **green**. All three Lab 2 tiles are now green — close the P2 incident in ServiceNow with both root causes recorded: node group scaled to zero, and a default-deny egress NetworkPolicy with no allow rule.

---

## Troubleshooting

### `kubectl` says `Unauthorized` or `the server has asked for the client to provide credentials`

**Fix:** Re-run Task 1, step 5. If it persists, you are not on your lab host as `ec2-user`, or Lab 1 Start Here step 7 did not finish: run `sudo su - ec2-user`, then repeat that step.

### No node reaches `Ready` after 10 minutes

**Check:** Re-run step 11. `desiredSize` must be `2`. If it is still `0`, step 13 did not apply: re-run it and read its output for an error. Do **not** run `terraform apply -var scenario=lab2` to fix this; that re-injects the fault.

### The `nettest` / `dnstest` pod stays `Pending` or the command hangs for minutes

**Check:** `kubectl get nodes` must show nodes `Ready`; the test pods need somewhere to run. Finish Task 5 first. To clear a stuck test pod: `kubectl -n orders delete pod nettest dnstest --ignore-not-found`.

### `Pod → internet` / `Pod → DNS` stay red after step 20

**Fix:** The connectivity checker runs once a minute and must first install its packages, so allow 2–3 minutes and click the dashboard's refresh icon. Confirm `kubectl -n orders get networkpolicy` lists `orders-allow-egress`.

---

## Knowledge Check

**Question 1:** A pod is `Pending`; a different pod is `CrashLoopBackOff`. What does each status tell you about *where* the problem is, and which tool gives you the authoritative reason for a `Pending` pod?

**Answer:** `Pending` means the pod has not been **scheduled onto a node** — it is a placement/capacity problem at the cluster level, before the container ever starts. `CrashLoopBackOff` means the pod *was* scheduled and the container started but keeps exiting — an application/runtime problem inside the container. For a `Pending` pod, the authoritative reason is the **`FailedScheduling` event** from `kubectl describe pod` (the scheduler records exactly why it could not place the pod, e.g. "no nodes available" or "Insufficient cpu").

**Question 2:** You restored the node group with `update-nodegroup-config`. Where does scheduling capacity in EKS come from, and why did scaling to zero make *every* pod Pending rather than just some?

**Answer:** Capacity comes from the cluster's **managed node group** (the EC2 worker nodes) — or from Fargate profiles for Fargate pods. With the node group at `desiredSize=0`, there are **no worker nodes at all**, so the scheduler has nowhere to place *any* pod that needs a node — including the application pods and even system pods like CoreDNS. It is not a per-pod resource squeeze; it is a total absence of nodes, which is why the failure is global.

**Question 3:** The default-deny NetworkPolicy existed and was correct, yet on a cluster without VPC CNI NetworkPolicy enforcement it would have had no effect. Explain the dependency, and why DNS broke alongside internet egress.

**Answer:** A Kubernetes NetworkPolicy is only a *declaration* — something must enforce it in the data plane. On EKS the **VPC CNI enforces NetworkPolicies only when `enableNetworkPolicy=true`** is set on the `vpc-cni` addon; otherwise the policy is silently ignored and traffic flows as if it were not there. In this lab enforcement is on, so the **default-deny egress** dropped *all* outbound traffic from the pods it selects. DNS broke alongside the internet because resolving a name requires the pod to send packets to **CoreDNS in `kube-system`** — that is egress too, so a blanket egress deny takes out name resolution as well as direct internet access. The fix must explicitly allow egress to UDP/TCP 53 toward kube-system.

---

## Lab Summary

You worked a **P2** EKS workload outage from the board to green. Pods stuck `Pending` led you — via the scheduler's own `FailedScheduling` event and the EKS API — to a managed node group scaled to **zero**; `update-nodegroup-config` restored capacity and `EKS pods schedulable` recovered. Then you chased a quieter add-on: pods that could not reach the internet or DNS. From inside a container you proved egress and DNS were blocked, found a **default-deny egress NetworkPolicy**, confirmed the **VPC CNI was enforcing it** (`enableNetworkPolicy=true`), and opened targeted egress — turning `Pod → internet` and `Pod → DNS` green.

## Completion Checklist

- [ ] Lab 2 tiles confirmed red (incident logged as P2 in ServiceNow)
- [ ] Pods observed `Pending`; `FailedScheduling` event read from `kubectl describe`
- [ ] Root cause confirmed: node group `io108-<your-id>-nodes` at `desiredSize=0` (no nodes registered)
- [ ] Node group scaled to `minSize=2,desiredSize=2,maxSize=3`; pods reach `Running`; `EKS pods schedulable` green
- [ ] Pod egress + DNS failure reproduced from inside a container (Python socket tests)
- [ ] Default-deny egress NetworkPolicy found; VPC CNI enforcement (`enableNetworkPolicy=true`) confirmed
- [ ] Targeted egress allowed (or chart redeployed); `Pod → internet` and `Pod → DNS` green

---

## Next Steps

In **Lab 3: Lambda and Step Functions Performance Incident**, the `Reports flowing` tile goes red — the scheduled report workflow is failing under throttling/timeout. You will diagnose the Lambda and Step Functions execution, and meet the event fan-out that distributes alarms to the simulated NewRelic and SolarWinds monitoring sinks.
