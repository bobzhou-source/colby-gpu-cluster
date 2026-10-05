import Foundation

struct SlurmCommandDefinition: Equatable, Sendable {
    let id: String
    let domain: SlurmDataDomain
    let parserKind: SlurmParserKind
    let columns: [String]
    let shell: String
}

enum SlurmDataCommands {
    static let beginMarker = "__COLBY_SLURM_BEGIN_7F3A5C9D_V1__"
    static let endMarker = "__COLBY_SLURM_END_7F3A5C9D_V1__"

    static func definitions(for domain: SlurmDataDomain) -> [SlurmCommandDefinition] {
        switch domain {
        case .controllerConfiguration:
            return [
                definition(
                    "controller-version",
                    domain,
                    .plainLines,
                    ["Line"],
                    "scontrol --version"
                ),
                definition(
                    "controller-ping",
                    domain,
                    .plainLines,
                    ["Line"],
                    "scontrol ping"
                ),
                definition(
                    "controller-config",
                    domain,
                    .keyValueLines,
                    [
                        "ClusterName", "SlurmctldHost", "SlurmctldPort", "SlurmctldParameters",
                        "SlurmctldTimeout", "SlurmdPort", "SlurmdTimeout", "SchedulerType",
                        "SchedulerParameters", "SelectType", "SelectTypeParameters", "PriorityType",
                        "PriorityParameters", "PreemptMode", "PreemptType", "AccountingStorageType",
                        "AccountingStorageHost", "AccountingStoragePort", "AccountingStorageTRES",
                        "JobAcctGatherType", "JobAcctGatherFrequency", "ProctrackType", "TaskPlugin",
                        "CgroupPlugin", "PluginDir", "GresTypes", "TopologyPlugin",
                    ],
                    "scontrol show config"
                ),
                definition(
                    "dbd-config",
                    domain,
                    .keyValueLines,
                    [
                        "ArchiveDir", "ArchiveEvents", "ArchiveJobs", "ArchiveResvs", "ArchiveSteps",
                        "ArchiveSuspend", "ArchiveTXN", "ArchiveUsage", "AuthType", "DbdHost", "DbdPort",
                        "DebugLevel", "LogFile", "MessageTimeout", "PidFile", "PluginDir", "PrivateData",
                        "PurgeEventAfter", "PurgeJobAfter", "PurgeResvAfter", "PurgeStepAfter",
                        "PurgeSuspendAfter", "PurgeTXNAfter", "PurgeUsageAfter", "StorageHost",
                        "StorageLoc", "StoragePort", "StorageType",
                    ],
                    "sacctmgr show config"
                ),
            ]

        case .partitions:
            return [
                definition(
                    "partition-summary",
                    domain,
                    .pipeTable,
                    [
                        "Partition", "Available", "TimeLimit", "NodeCount", "CPUsState", "GRES",
                        "Memory", "CPUsPerNode", "State", "NodeList",
                    ],
                    "sinfo --noheader --exact --format='%P|%a|%l|%D|%C|%G|%m|%c|%t|%N'"
                ),
                definition(
                    "partition-details",
                    domain,
                    .keyValueRecord,
                    [
                        "PartitionName", "AllowAccounts", "AllowGroups", "AllowQos", "AllocNodes",
                        "Alternate", "BillingWeights", "CpuBind", "Default", "DefaultTime", "DefMemPerCPU",
                        "DefMemPerNode", "DenyAccounts", "DenyQos", "DisableRootJobs", "ExclusiveUser",
                        "GraceTime", "Hidden", "LLN", "MaxCPUsPerNode", "MaxMemPerCPU", "MaxMemPerNode",
                        "MaxNodes", "MaxTime", "MinNodes", "Nodes", "OverSubscribe", "PreemptMode",
                        "PriorityJobFactor", "PriorityTier", "QOS", "ReqResv", "RootOnly", "SelectTypeParameters",
                        "State", "TRES", "JobDefaults",
                    ],
                    "scontrol --oneliner show partition"
                ),
            ]

        case .nodesResources:
            return [
                definition(
                    "node-summary",
                    domain,
                    .pipeTable,
                    [
                        "NodeName", "State", "Reason", "CPULoad", "CPUsState", "Memory", "FreeMemory",
                        "Features", "GRES", "Partitions",
                    ],
                    "sinfo --Node --noheader --exact --format='%N|%T|%E|%O|%C|%m|%e|%f|%G|%P'"
                ),
                definition(
                    "node-details",
                    domain,
                    .keyValueRecord,
                    [
                        "NodeName", "Arch", "CoresPerSocket", "CPUAlloc", "CPUEfctv", "CPUErr", "CPULoad",
                        "CPUTot", "CfgTRES", "AllocTRES", "CurrentWatts", "AvailableFeatures", "ActiveFeatures",
                        "Gres", "GresDrain", "GresUsed", "LastBusyTime", "MCS_label", "MemSpecLimit", "OS",
                        "RealMemory", "AllocMem", "FreeMem", "Reason", "ReasonTime", "ReasonUid", "Partitions",
                        "Power", "State", "ThreadsPerCore", "TmpDisk", "Weight", "BootTime", "SlurmdStartTime",
                        "Version", "NodeAddr", "NodeHostName",
                    ],
                    "scontrol --oneliner show nodes"
                ),
            ]

        case .resourceCatalog:
            return [
                definition(
                    "tres-catalog",
                    domain,
                    .pipeTable,
                    ["Type", "Name", "ID"],
                    "sacctmgr --noheader --parsable2 show tres format=Type,Name,ID"
                ),
                definition(
                    "resource-catalog",
                    domain,
                    .pipeTable,
                    ["Name", "Server", "Type", "Count", "LastConsumed", "Allocated", "Cluster"],
                    "sacctmgr --noheader --parsable2 show resource format=Name,Server,Type,Count,LastConsumed,Allocated,Cluster"
                ),
                definition(
                    "license-catalog",
                    domain,
                    .keyValueRecord,
                    ["LicenseName", "Total", "Used", "Free", "Reserved", "Remote"],
                    "scontrol --oneliner show licenses"
                ),
                definition(
                    "reservation-catalog",
                    domain,
                    .keyValueRecord,
                    [
                        "ReservationName", "StartTime", "EndTime", "Duration", "Nodes", "NodeCnt", "CoreCnt",
                        "Features", "PartitionName", "Flags", "TRES", "Users", "Accounts", "Licenses", "State",
                        "MaxStartDelay",
                    ],
                    "scontrol --oneliner show reservation"
                ),
                definition(
                    "topology-catalog",
                    domain,
                    .keyValueRecord,
                    ["SwitchName", "Level", "LinkSpeed", "Nodes", "Switches", "BlockName"],
                    "scontrol --oneliner show topology"
                ),
                definition(
                    "topology-config",
                    domain,
                    .keyValueRecord,
                    [
                        "TopologyPlugin", "TopologyParam", "SwitchName", "Switches", "Nodes", "LinkSpeed",
                        "BlockName", "BlockSizes",
                    ],
                    "scontrol --oneliner show topoconf"
                ),
                definition(
                    "cluster-catalog",
                    domain,
                    .pipeTable,
                    [
                        "Cluster", "ControlHost", "ControlPort", "RPC", "Flags", "PluginIDSelect",
                        "AccountingStorageTRES", "Federation", "Features",
                    ],
                    "sacctmgr --noheader --parsable2 show cluster format=Cluster,ControlHost,ControlPort,RPC,Flags,PluginIDSelect,AccountingStorageTRES,Federation,Features"
                ),
                definition(
                    "federation-catalog",
                    domain,
                    .pipeTable,
                    ["Federation", "Cluster", "Features"],
                    "sacctmgr --noheader --parsable2 show federation format=Federation,Cluster,Features"
                ),
            ]

        case .activeJobs:
            return [
                definition(
                    "global-active-queue",
                    domain,
                    .pipeTable,
                    [
                        "JobID", "ArrayJobID", "ArrayTaskID", "Name", "User", "UserID", "Account", "StateLong",
                        "State", "Partition", "CPUs", "Nodes", "GRES", "NodeList", "SubmitTime", "StartTime",
                        "TimeUsed", "TimeLimit", "TimeLeft", "Reason", "Dependency", "Priority", "QOS",
                    ],
                    "squeue --noheader --format='%i|%F|%K|%j|%u|%U|%a|%T|%t|%P|%C|%D|%b|%N|%V|%S|%M|%l|%L|%R|%E|%Q|%q'"
                ),
                definition(
                    "own-active-job-details",
                    domain,
                    .keyValueRecord,
                    [
                        "JobId", "ArrayJobId", "ArrayTaskId", "JobName", "UserId", "GroupId", "MCS_label",
                        "Priority", "Nice", "Account", "QOS", "JobState", "Reason", "Dependency", "Requeue",
                        "Restarts", "BatchFlag", "Reboot", "ExitCode", "RunTime", "TimeLimit", "TimeMin",
                        "SubmitTime", "EligibleTime", "AccrueTime", "StartTime", "EndTime", "Deadline",
                        "SuspendTime", "LastSchedEval", "Partition", "AllocNode:Sid", "ReqNodeList", "ExcNodeList",
                        "NodeList", "BatchHost", "NumNodes", "NumCPUs", "NumTasks", "CPUs/Task", "ReqB:S:C:T",
                        "ReqTRES", "AllocTRES", "Socks/Node", "NtasksPerN:B:S:C", "CoreSpec", "MinCPUsNode",
                        "MinMemoryNode", "MinTmpDiskNode", "Features", "DelayBoot", "OverSubscribe", "Contiguous",
                        "Licenses", "Network", "Command", "WorkDir", "StdErr", "StdIn", "StdOut", "Power",
                        "TresPerNode", "TresPerTask",
                    ],
                    ownJobLoop(command: "scontrol --oneliner show job \"$colby_job_id\"")
                ),
            ]

        case .stepsRuntime:
            return [
                definition(
                    "own-active-step-details",
                    domain,
                    .keyValueRecord,
                    [
                        "StepId", "StepName", "UserId", "StartTime", "TimeLimit", "Partition", "State",
                        "NodeList", "Nodes", "CPUs", "Tasks", "TRES", "SrunHost:Pid", "Network",
                        "ResvPorts", "CPUFreqReq", "JobId",
                    ],
                    ownJobLoop(command: "scontrol --oneliner show step \"$colby_job_id\"")
                ),
                definition(
                    "own-active-step-metrics",
                    domain,
                    .pipeTable,
                    [
                        "JobID", "MaxRSS", "MaxVMSize", "AveCPU", "AveRSS", "AveVMSize", "AveDiskRead",
                        "AveDiskWrite", "NTasks", "ConsumedEnergy", "Elapsed",
                    ],
                    ownJobLoop(
                        command: "sstat --allsteps --noheader --parsable2 --jobs=\"$colby_job_id\" --format=JobID,MaxRSS,MaxVMSize,AveCPU,AveRSS,AveVMSize,AveDiskRead,AveDiskWrite,NTasks,ConsumedEnergy,Elapsed"
                    )
                ),
            ]

        case .priorityScheduling:
            return [
                definition(
                    "global-priority",
                    domain,
                    .pipeTable,
                    [
                        "JobID", "User", "Account", "Partition", "QOS", "Priority", "Age", "Association",
                        "FairShare", "JobSize", "PartitionFactor", "QOSFactor", "TRESFactor",
                    ],
                    "sprio --noheader --format='%i|%u|%a|%p|%q|%Y|%A|%B|%F|%J|%P|%Q|%T'"
                ),
                definition(
                    "own-priority",
                    domain,
                    .pipeTable,
                    [
                        "JobID", "User", "Account", "Partition", "QOS", "Priority", "Age", "Association",
                        "FairShare", "JobSize", "PartitionFactor", "QOSFactor", "TRESFactor",
                    ],
                    "sprio --noheader --user=\"$USER\" --format='%i|%u|%a|%p|%q|%Y|%A|%B|%F|%J|%P|%Q|%T'"
                ),
                definition(
                    "global-start-estimates",
                    domain,
                    .pipeTable,
                    ["JobID", "User", "Account", "Partition", "State", "StartTime", "Priority", "Reason"],
                    "squeue --start --noheader --format='%i|%u|%a|%P|%T|%S|%Q|%R'"
                ),
                definition(
                    "own-start-estimates",
                    domain,
                    .pipeTable,
                    ["JobID", "User", "Account", "Partition", "State", "StartTime", "Priority", "Reason"],
                    "squeue --start --noheader --user=\"$USER\" --format='%i|%u|%a|%P|%T|%S|%Q|%R'"
                ),
            ]

        case .schedulerDiagnostics:
            return [
                definition(
                    "scheduler-backfill-diagnostics",
                    domain,
                    .hierarchicalKeyValue,
                    ["Section", "Key", "Value"],
                    "sdiag"
                ),
                definition(
                    "scheduler-rpc-diagnostics",
                    domain,
                    .hierarchicalKeyValue,
                    ["Section", "Key", "Value"],
                    "sdiag --all"
                ),
            ]

        case .accounting:
            return [
                definition(
                    "own-accounting-31d",
                    domain,
                    .pipeTable,
                    [
                        "JobIDRaw", "JobID", "JobName", "User", "Account", "Partition", "State", "ExitCode",
                        "Submit", "Eligible", "Start", "End", "Elapsed", "Timelimit", "NNodes", "NCPUS",
                        "ReqCPUS", "ReqMem", "AllocTRES", "ReqTRES", "Reason",
                    ],
                    "sacct --starttime=now-31days --endtime=now --user=\"$USER\" --allocations --noheader --parsable2 --format=JobIDRaw,JobID,JobName,User,Account,Partition,State,ExitCode,Submit,Eligible,Start,End,Elapsed,Timelimit,NNodes,NCPUS,ReqCPUS,ReqMem,AllocTRES,ReqTRES,Reason"
                ),
                definition(
                    "accounting-events-31d",
                    domain,
                    .pipeTable,
                    [
                        "Cluster", "ClusterNodes", "NodeName", "Start", "End", "State", "Reason", "ReasonRaw",
                        "TRES", "User",
                    ],
                    "sacctmgr --noheader --parsable2 show event where start=now-31days end=now format=Cluster,ClusterNodes,NodeName,Start,End,State,Reason,ReasonRaw,TRES,User"
                ),
                definition(
                    "cluster-utilization-31d",
                    domain,
                    .pipeTable,
                    ["Cluster", "Allocated", "Down", "PlannedDown", "Idle", "Overcommitted", "Reported"],
                    "sreport --noheader --parsable2 cluster utilization start=now-31days end=now format=Cluster,Allocated,Down,PlannedDown,Idle,Overcommitted,Reported"
                ),
                definition(
                    "own-usage-31d",
                    domain,
                    .pipeTable,
                    ["Cluster", "Login", "ProperName", "Account", "Used", "Energy"],
                    "sreport --noheader --parsable2 user top start=now-31days end=now users=\"$USER\" format=Cluster,Login,ProperName,Account,Used,Energy"
                ),
            ]

        case .policy:
            return [
                definition(
                    "own-fairshare",
                    domain,
                    .pipeTable,
                    [
                        "Cluster", "Account", "User", "RawShares", "NormShares", "RawUsage", "NormUsage",
                        "EffectvUsage", "FairShare", "LevelFS", "GrpTRESMins", "TRESRunMins",
                    ],
                    "sshare --noheader --parsable2 --user=\"$USER\" --format=Cluster,Account,User,RawShares,NormShares,RawUsage,NormUsage,EffectvUsage,FairShare,LevelFS,GrpTRESMins,TRESRunMins"
                ),
                definition(
                    "own-user-policy",
                    domain,
                    .pipeTable,
                    ["User", "DefaultAccount", "DefaultQOS", "Admin"],
                    "sacctmgr --noheader --parsable2 show user where name=\"$USER\" format=User,DefaultAccount,DefaultQOS,Admin"
                ),
                definition(
                    "own-associations",
                    domain,
                    .pipeTable,
                    [
                        "Cluster", "Account", "User", "Partition", "Share", "Priority", "MaxJobs",
                        "MaxJobsAccrue", "MaxSubmit", "MaxWall", "QOS", "DefaultQOS", "GrpTRES", "MaxTRES",
                        "MaxTRESPJ", "MaxTRESPN",
                    ],
                    "sacctmgr --noheader --parsable2 show association where user=\"$USER\" format=Cluster,Account,User,Partition,Share,Priority,MaxJobs,MaxJobsAccrue,MaxSubmit,MaxWall,QOS,DefaultQOS,GrpTRES,MaxTRES,MaxTRESPJ,MaxTRESPN"
                ),
                definition(
                    "own-account-policy",
                    domain,
                    .pipeTable,
                    ["Account", "Description", "Organization"],
                    ownAccountLoop
                ),
                definition(
                    "own-qos-policy",
                    domain,
                    .pipeTable,
                    [
                        "Name", "Priority", "Preempt", "PreemptMode", "Flags", "UsageFactor", "UsageThreshold",
                        "GrpTRES", "MaxTRES", "MaxTRESPJ", "MaxWall", "MaxJobsPU", "MaxSubmitPU",
                    ],
                    ownQOSLoop
                ),
                definition(
                    "wckey-permission-probe",
                    domain,
                    .pipeTable,
                    ["Cluster", "WCKey", "User"],
                    "sacctmgr --noheader --parsable2 show wckey where user=\"$USER\" format=Cluster,WCKey,User"
                ),
                definition(
                    "dbd-stats-permission-probe",
                    domain,
                    .hierarchicalKeyValue,
                    ["Section", "Key", "Value"],
                    "sacctmgr show stats"
                ),
            ]
        }
    }

    static func script(for domain: SlurmDataDomain) -> String {
        definitions(for: domain).map { command in
            """
            printf '%s\n' '\(beginMarker)|\(command.id)'
            (
            \(command.shell)
            )
            colby_slurm_section_exit=$?
            printf '%s|%s|%d\n' '\(endMarker)' '\(command.id)' "$colby_slurm_section_exit"
            """
        }.joined(separator: "\n")
    }

    static func ttl(for domain: SlurmDataDomain) -> TimeInterval {
        switch domain {
        case .nodesResources, .activeJobs, .priorityScheduling:
            return 60
        case .stepsRuntime, .schedulerDiagnostics:
            return 300
        case .accounting, .policy:
            return 1_800
        case .controllerConfiguration, .partitions, .resourceCatalog:
            return 3_600
        }
    }

    private static func definition(
        _ id: String,
        _ domain: SlurmDataDomain,
        _ parserKind: SlurmParserKind,
        _ columns: [String],
        _ shell: String
    ) -> SlurmCommandDefinition {
        SlurmCommandDefinition(
            id: id,
            domain: domain,
            parserKind: parserKind,
            columns: columns,
            shell: shell
        )
    }

    private static func ownJobLoop(command: String) -> String {
        """
        colby_job_ids=$(squeue --noheader --user="$USER" --format='%A') || exit $?
        colby_loop_status=0
        for colby_job_id in $colby_job_ids; do
            case "$colby_job_id" in
                ''|*[!0-9_+.-]*) continue ;;
            esac
            \(command) || colby_loop_status=$?
        done
        exit "$colby_loop_status"
        """
    }

    private static let ownAccountLoop = """
    colby_accounts=$(sacctmgr --noheader --parsable2 show association where user="$USER" format=Account) || exit $?
    colby_loop_status=0
    for colby_account in $(printf '%s\n' "$colby_accounts" | tr '|' ' '); do
        case "$colby_account" in
            ''|*[!A-Za-z0-9_.+-]*) continue ;;
        esac
        sacctmgr --noheader --parsable2 show account where name="$colby_account" format=Account,Description,Organization || colby_loop_status=$?
    done
    exit "$colby_loop_status"
    """

    private static let ownQOSLoop = """
    colby_qos_values=$(sacctmgr --noheader --parsable2 show association where user="$USER" format=QOS,DefaultQOS) || exit $?
    colby_loop_status=0
    for colby_qos in $(printf '%s\n' "$colby_qos_values" | tr ',|' '  '); do
        case "$colby_qos" in
            ''|*[!A-Za-z0-9_.+-]*) continue ;;
        esac
        sacctmgr --noheader --parsable2 show qos where name="$colby_qos" format=Name,Priority,Preempt,PreemptMode,Flags,UsageFactor,UsageThreshold,GrpTRES,MaxTRES,MaxTRESPJ,MaxWall,MaxJobsPU,MaxSubmitPU || colby_loop_status=$?
    done
    exit "$colby_loop_status"
    """
}
