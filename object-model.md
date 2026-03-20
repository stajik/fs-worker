# Object Model

### worker side
```python

class FsBranch:
    id
    snapshot_id

class FsSnapshot:
    id
    
class VmTemplate:
    """Serialized state of a VM already ran user's setup scripts. Templates are stored in S3 and
    cached in each host's memory to be able to run new VM instances off of them quickly."""
    id

class VmRun:
    """An instance of the VM"""
    id
    command
    is_read_only
    template_id
    base_snapshot_id
    is_fs_mem_dirty
    is_fs_disk_dirty
    timeout
    
    def _flush(): """Flush FS memory pages into disk. Called internally by the worker."""
    def _capture(snapshot_id): """Captures the FS disk content in a new snapshot. Called internally by the worker."""

class HostWorker:
    """A stateless worker just to perform incomming tasks on MVs ans FSs. 
    Since most operations write things to disk, we do not expect the worker to always cleanup all the mess in crash situations.
    The control-plain always ensures the needed cleanups are executed."""
    
    
    ##### Branch APIs #####
    def init_branch(id):
        """Create an empty filesystem branch."""
    def load_branch(id, snapshot_ids):
    def fork_branch(id, base_snapshot_id):
    
    ##### Exec APIs #####
    def exec(command, run_id, vm_template_id, base_snapshot_id, target_snapshot_id, timeout): 
        """Executes the given command on the given vm template and base FS snapshot. 
        If the command doesn't fail, the target snapshot will be created with all the new writes.
        base_snapshot_id could be nil in which case an empty FS will be used.""" 
    
    def exec_readonly(command, run_id, vm_template_id, base_snapshot_id, timeout): 
        """Executes the given command on the given vm template and base FS snapshot as a readonly mount.
        This command is completely disk-write-free.""" 
        
    def exec_native(command, args, base_snapshot_id, target_snapshot_id, timeout): 
        """Executes built-in commands natively without running a vm. Otherwise, same semantics as `exec`."""
        
    def exec_native_readonly(command, args, base_snapshot_id, timeout): 
        """Executes built-in readonly commands natively without running a vm. Otherwise, same semantics as `exec_readonly`."""
        
    def receive(base_snapshot_id, target_snapshot_id, delta):
        """Called by another host, to sync snapshot deltas."""
    
    def delete_snapshot(id): """Deletes the snapshot from disk. Assumes it has no child snapshots."""
    
    
    ##### Control Plain #####
    
    def create_template(id, setup_commands): """Creates a template based on setup_commands and stores it in S3."""

    def delete_template(id): """Deletes the template from S3 and unloads it from memory."""

```

### Controller Side
