use YAML::XS;
use Parse::CSV;
use JSON;
use Data::Dumper;
use Time::Local;
use Date::Parse;
use WWW::Curl::Easy;
use WWW::Curl::Multi;
use DBI;
use POSIX;
use strict;

sub open_csv
    {
    my $fname=shift;
    # print STDERR "--> $fname\n\n";
    my $csv_handel=Parse::CSV->new(file=>$fname,names=>1);    
    return $csv_handel;
    }

# $projects->uuid = [project uuid]
#                ->name = [project name]
#                ->id   = [project id in cloud forms (will go away)]
#                ->VM   = [hash of VMs in this project (added later)] MVP
#                ->Vol  = [hash of the Volumes in this project (added later)] MVP
#                ->Obj  = [hash of the object stores in this project (added later)]
#          ->os_id->Con  = [has of the containers in this project (added later) ]

sub read_projects
    {
    my $fname=shift;
    my $proj;

    my $data_set=open_csv($fname);

    # id,name,ems_ref,ems_id,description
    while(my $line=$data_set->fetch())
        {
        my $id=$line->{'id'};
        $proj->{$id}->{'name'} = $line->{'name'};
        $proj->{$id}->{'uuid'} = $line->{'ems_ref'};
        $proj->{$id}->{'vm_cnt'} = 0;
        $proj->{$id}->{'vol_cnt'} = 0;
        $proj->{$id}->{'event_cnt'} = 0;
        #$proj->{$id}->{} = $line{'ems_id'};
        }
    #print Dumper($proj);
    return $proj;
    }

sub read_flavors
    {
    my $fname=shift;
    my $flavor;

    my $data_set=open_csv($fname);
    # id,name,cpus,memory,root_disk_size,ems_ref
    while(my $line=$data_set->fetch())
        {
        my $id=$line->{'id'};
        $flavor->{$id}->{'name'}=$line->{'name'};
        $flavor->{$id}->{'cpus'}=$line->{'cpus'};
        $flavor->{$id}->{'mem'}=$line->{'memory'}/1073741824;
        $flavor->{$id}->{'disk'}=1.0*$line->{'root_disk_size'}/1073741824;
        $flavor->{$id}->{'cost'}= 0.1*$line->{'cpus'} + 0.2*$flavor->{'mem'};
        }
    return $flavor;
    }

# This takes a projct datastructure and adds in the VM information
sub read_vms
    {
    my $proj=shift;
    my $fname=shift;
    
    my $data_set=open_csv($fname);
    #id,name,guid,flavor_id,tenant_id
    while(my $line=$data_set->fetch())
        {
        my $proj_id = $line->{'tenant_id'};
        #my $uuid = $line->{'guid'};
        my $uuid = $line->{'id'};
        $proj->{$proj_id}->{'vm_cnt'}=1; # just set this to 1 for now.
        $proj->{$proj_id}->{'VM'}->{$uuid}->{'event_cnt'}=0;
        $proj->{$proj_id}->{'VM'}->{$uuid}->{'name'}=$line->{'name'};
        $proj->{$proj_id}->{'VM'}->{$uuid}->{'flavor_id'}=$line->{'flavor_id'};
        $proj->{$proj_id}->{'VM'}->{$uuid}->{'id'}=$line->{'id'};
        $proj->{$proj_id}->{'VM'}->{$uuid}->{'id'}=$line->{'guid'};
        }

    # count up the VMs
    # not yet though.
    return $proj;
    }
 
sub read_vol
    {
    my $proj=shift;
    my $fname=shift;
    
    my $data_set=open_csv($fname);
    #id,name,ems_ref,cloud_tenant_id,volume_type
    while(my $line=$data_set->fetch())
        {
        my $proj_id = $line->{'cloud_tenant_id'};
        my $uuid = $line->{'id'};
        $proj->{$proj_id}->{vol_cnt}=1;
        $proj->{$proj_id}->{'VOL'}->{$uuid}->{'name'}=$line->{'name'};     
        $proj->{$proj_id}->{'VOL'}->{$uuid}->{'type'}=$line->{'volume_type'};     
        $proj->{$proj_id}->{'VOL'}->{$uuid}->{'type'}=$line->{'ems_ref'};    # this is the openstack uuid     
        #$proj->{$proj_id}->{'VOL'}->{$uuid}->{'size'}=$line->{'size'};     
        
        }
    return $proj;
    }


# stage2 process how long it has been used

# data->$project_id->project_name
#                  ->user_id->username
#                           ->$instance_id->instance_name
#                                         ->{timestamp}->event_type
#                                                      ->vCPU
#                                                      ->mem
#                                                      ->disk
sub process_oslo_json
    {
    my $json_string=shift;
    my $data;
    if($json_string =~ /^'(.*)'$/) { $json_string=$&; }
    my $eq = from_json($json_string);
    #print Dumper($eq);
    #print("_context_domain=".$eq->{_context_domain}."\n");

    #find the project_id
    my $project_id=$eq->{_context_project_id};
    if(!$project_id) { $project_id=$eq->{payload}->{tenant_id}; }
    if(!$project_id) { $project_id=$eq->{payload}->{project_id}; }

    my $user_id=$eq->{_context_user_id};
    if(!$user_id) { $user_id=$eq->{payload}->{user_id};}

    $data->{timestamp} = $eq->{timestamp};
    $data->{project_id} = $project_id;
    $data->{instance_id} = $eq->{payload}->{instance_id};
    $data->{user_id} = $user_id;
    $data->{cpu} = $eq->{payload}->{vcpus};
    $data->{mem} = $eq->{payload}->{memory_mb};
    $data->{root_gb} = $eq->{payload}->{root_gb};
    $data->{state} = $eq->{payload}->{state};
    $data->{flavor} = $eq->{payload}->{instance_type};
    return $data;
    }

sub process_vm_msg
    {
    my $msg=shift;
    my $data;
    my $eq;
   
    $msg =~ /\-\-\-/;
    $msg =~ $';
    # print "-->".$msg."\n";
    my $yaml=YAML::XS::Load $msg;
    # print Dumper($yaml);
    if(exists $yaml->{':content'} and exists $yaml->{':content'}->{'oslo.message'})
        {
        $data=process_oslo_json($yaml->{':content'}->{'oslo.message'});
        }
    elsif( exists $yaml->{':content'} and exists $yaml->{':content'}->{'payload'})
        {
        $data->{timestamp} = $yaml->{timestamp};
        $data->{project_id} = $yaml->{payload}->{project_id};
        if(!($data->{project_id})) { $data->{project_id} = $yaml->{':content'}->{payload}->{tenant_id}; }
        $data->{instance_id} = $yaml->{':content'}->{payload}->{instance_id};
        $data->{user_id} = $yaml->{':content'}->{payload}->{user_id};
        $data->{cpu} = $yaml->{':content'}->{payload}->{vcpus};
        $data->{mem} = $yaml->{':content'}->{payload}->{memory_mb};
        $data->{root_gb} = $yaml->{':content'}->{payload}->{root_gb};
        $data->{state} = $yaml->{':content'}->{payload}->{state};
        }
    return $data;
    }

sub build_instace_to_proj_index
    {
    my $proj=shift;
    my $index;

    foreach my $proj_id (keys $proj)
        {
        if($proj->{$proj_id}->{vm_cnt}>0)
            {
            my $vms = $proj->{$proj_id}->{VM};
            foreach my $vm_id (keys $vms)
                {
                $index->{$vm_id}=$proj_id;
                }
            } 
        }
    return $index;
    }

sub get_metrics_data
    {
    my $proj=shift;
    my $fname=shift;
    my $start_ts=shift;
    my $end_ts=shift;

    my $data_set=open_csv($fname);
    # timestamp, resource_id, resource_type, cpu_usage_rate_average,capture_interval,capture_interval_name 
    while(my $line=$data_set->fetch())
        {
        my $ts = $line->{'timestamp'};

        my $t=str2time($ts);
        my $st=str2time($start_ts);
        my $et=str2time($end_ts);
        my $i2p=build_instace_to_proj_index($proj);

        if($st <= $t and $t <= $et)
            {

            if($line->{'capture_interval_name'} eq 'Hourly' and $line->{'resource_type'} eq 'VmOrTemplate')
                {
                # print "$ts --> $proj_id  [ $msg->{instance_id} ]\n";
                my $uuid=$line->{resource_id};

                my $proj_id = $i2p->{$uuid};  # becuase there is no project id in the metrics table
                $proj->{$proj_id}->{'VM'}->{$uuid}->{event_cnt}=1;

                #add in the instance id to the hash right before the $ts
                if($line->{'cpu_usage_rage_average'}>0) 
                    {
                    $proj->{$proj_id}->{'VM'}->{$uuid}->{events}->{$ts}->{_id}=1;
                    }
                #print "$msg->{instance_id}, $msg->{cpu}, $msg->{mem} \n";
                #print "-------\n"
                }
            }
        }
    return $proj;
    }

sub get_mq_data
    {
    my $proj=shift;
    my $fname=shift;
    my $start_ts=shift;
    my $end_ts=shift;
    
    my $data_set=open_csv($fname);
    # id,ems_id,event_type,timestamp,full_data
    while(my $line=$data_set->fetch())
        {
        my $ts = $line->{'timestamp'};
        
        my $t=str2time($ts);
        my $st=str2time($start_ts);
        my $et=str2time($end_ts);

        if($st <= $t and $t <= $et)
            {
            
            if($line->{'event_type'} =~ /compute.instance.exists/)
                {
                my $proj_id = $line->{'ems_id'};
                my $msg=process_vm_msg($line->{'full_data'});
                # print "$ts --> $proj_id  [ $msg->{instance_id} ]\n";
                my $uuid=$msg->{instance_id};
                $proj->{$proj_id}->{'VM'}->{$uuid}->{event_cnt}=1;
            

                #add in the instance id to the hash right before the $ts
                $proj->{$proj_id}->{'VM'}->{$uuid}->{events}->{$ts}->{instance_id}=$msg->{instance_id};
                $proj->{$proj_id}->{'VM'}->{$uuid}->{events}->{$ts}->{cpu}=$msg->{cpu};
                $proj->{$proj_id}->{'VM'}->{$uuid}->{events}->{$ts}->{mem}=$msg->{mem};
                $proj->{$proj_id}->{'VM'}->{$uuid}->{events}->{$ts}->{root_gb}=$msg->{root_gb};
                $proj->{$proj_id}->{'VM'}->{$uuid}->{events}->{$ts}->{state}=$msg->{state};
                #print "$msg->{instance_id}, $msg->{cpu}, $msg->{mem} \n";
                #print "-------\n"
                }
            if($line->{'event_type'} =~ /volume/)
                {
                my $proj_id = $line->{'ems_id'};
                my $ts = $line->{'timestamp'};
                print "found a $line->{'event_type'} \n";
                }
            }
        }
    return $proj;
    }



# tally hours
# 1) find the first event
#    a) power-on -> $start_time = power-on timestamp, power_on=1
#    b) power-off - $start_time = $t1, $end_time = power-off timestamp; $amt= time diff ($start_time, $end_time); $start_time=undef, $end_time=undef; power_on=0;
#    c) exists status=active $start_time=$t1 power_on=1
#    d) exists status!=active power_on=0;
#
# 2) for each event
#    a) if power_on == 1
#       i) power_on -> issue a warning
#          $end_time=$last event; $amt=timediff($start_time,$end_time); $start_time=this->timestamp; $end_time=undef; power_on=0;
#       ii) power_off -> 
#          $end_time=$this event; $amt=timediff($start_time,$end_time); $start_time=undef; $end_time=undef; power_on=0;
#       iii) exists = active ->
#             $end_time=this event;
#       iv) exists != active -> issue a warning
#          $end_time=$last event; $amt=timediff($start_time,$end_time); $start_time=this->timestamp; $end_time=undef; power_on=0;
#    b) if power_on == 0
#       i) power_on -> 
#          $end_time=$this event; $amt=timediff($start_time,$end_time); $start_time=undef; $end_time=undef; power_on=0;
#       ii) power_off-> issue a warning
#          power_on=0;
#       iii) exists = active -> issue a warning (we missed the power on even - start from here)
#             $start_time=this event; power_on=1
#       iv) exists != active -> 
#           power_on=0;
#
#  This needs to be reworked
#  
#
sub tally_hours
    {
    my $events=shift;
    my $t1=shift;
    my $t2=shift;

    my $start_time=undef;
    my $end_time=undef;
    my $power_on;
    my $total_time_on;
    my $time_on;
    
    my @ts = (sort keys $events);
    my $t = pop @ts;
    my $t2 = $events->{$t}->{end_ts};
    if($events->{$t}->{event_type} eq 'exists' and $events->{$t}->{status} eq 'acitive')
        {
        $start_time=$t1;
        $end_time=$t2;
        $power_on=1;
        }
    elsif($events->{$t}->{event_type} eq 'exists' and $events->{$t}->{status} ne 'acitive')
        {
        $start_time=undef;
        $end_time=undef;
        $power_on=0;
        }   
    elsif($events->{$t}->{event_type} eq 'power.on' and $events->{$t}->{status} eq 'acitive')
        {
        $start_time=$t; $end_time=undef;
        $power_on=1;
        }
    elsif($events->{$t}->{event_type} eq 'power.off' and $events->{$t}->{status} ne 'acitive')
        {
        $start_time=$t1;       $end_time=$t2;
        $time_on=timediff($start_time,$end_time);
        $total_time_on+=$time_on;
        # log this!!!
        $start_time=undef;     $end_time=undef;
        $power_on=0;
        }
    print STDERR $events->{$t}->{event_type}." ".$events->{$t}->{status}."  ".$start_time."   ".$end_time."  ".$power_on."\n";
    foreach $t (@ts)
        {
        if($power_on==1)
            {
            if($events->{$t}->{event_type} eq 'exists' and $events->{$t}->{status} eq 'acitive')
                {
                $end_time=$t2;
                $power_on=1;
                }
            elsif($events->{$t}->{event_type} eq 'exists' and $events->{$t}->{status} ne 'acitive')
                {
                # warning (going from power_on state to inactive - missed the power off?
                $time_on=timediff($start_time,$end_time);
                $total_time_on=$time_on;
                # log this !!!
                $start_time=undef;
                $end_time=undef;
                $power_on=0;
                }
            elsif($events->{$t}->{event_type} eq 'power.on' and $events->{$t}->{status} eq 'acitive')
                {
                # warning powered on state and turning the power on again - missed the power off?
                $time_on=timediff($start_time,$end_time);
                $total_time_on=$time_on;
                # log this !!!
                $start_time=$t1;
                $power_on=1;
                }
            elsif($events->{$t}->{event_type} eq 'power.off' and $events->{$t}->{status} ne 'acitive')
                {
                $end_time=$t1;
                $time_on=timediff($start_time,$end_time);
                $total_time_on+=$time_on;
                # log this!!!
                $start_time=undef;     $end_time=undef;
                $power_on=0;
                }
            }
        elsif($power_on==0)
            {
            if($events->{$t}->{event_type} eq 'exists' and $events->{$t}->{status}='acitive')
                {
                # warn - missed the power on event
                $start_time=$t;
                $end_time=$t;
                $power_on=1;
                }
            elsif($events->{$t}->{event_type} eq 'exists' and $events->{$t}->{status}!='acitive')
                {
                $start_time=undef;
                $end_time=undef;
                $power_on=0;
                }
            elsif($events->{$t}->{event_type} eq 'power.on' and $events->{$t}->{status}='acitive')
                {
                $start_time=$t; $end_time=$t;
                $power_on=1;
                }
            elsif($events->{$t}->{event_type} eq 'power.off' and $events->{$t}->{status}!='acitive')
                {
                # warn 2 power is off, and a power off event occured.  missed the power on - nothing to tally.
                $start_time=undef;     $end_time=undef;
                $power_on=0;
                }
            }
        print STDERR $events->{$t}->{event_type}." ".$events->{$t}->{status}."  ".$start_time."   ".$end_time."  ".$power_on."\n";
        }
    return $total_time_on
    }

sub tally_hours2
    {
    my $events=shift;
    my $flav=shift;
    my $t1=0;
    my $t2=0;

    my $start_time=undef;
    my $end_time=undef;
    my $power_on;
    my $total_time_on=0;
    my $total_amt=0.0;

    my @ts = (sort keys $events);
    my $t = pop @ts;
    $t1 = str2time($t);
    $t2 = str2time($events->{$t}->{end_ts});

    if($t2-$t1 < 0) 
        {
        print STDERR "bad time range\n";
        return 0;  
        }

    if($events->{$t}->{event_type} =~ /exists/ and $events->{$t}->{state} eq 'active')
        {
        $start_time=$t1;
        $end_time=$t2;
        if($t2 - $t1 < 3600) { $end_time = $t1 + 3600; }
        $power_on=1;
        }
    elsif($events->{$t}->{event_type} =~ /exists/ and $events->{$t}->{state} ne 'active')
        {
        $start_time=undef;
        $end_time=undef;
        $power_on=0;
        }
    foreach my $t (@ts)
        {
        if($events->{$t}->{event_type} =~ /exists/ and $events->{$t}->{state} eq 'active')
            {
            if($end_time > $t2) 
                {
                # do nothing
                #
                #   (t1' t2')  (t1', t2'')     (endtime (t1'+1hour))
                }
            if($end_time < $t1)
                {
                #   (t1' t2')    (t1'+1hour)      (t1'', t2'')
                #   (t1'                t2')      (t1'', t2'')
                $total_time_on += ($end_time - $start_time);
                $start_time=$t1;
                $end_time=$t2;
                if($end_time-$start_time<3600) { $end_time=$start_time+3600; }
                }
            if($t1 <= $end_time && $end_time < $t2)
                {
                #   (t1'            $t2')
                #                  ($t1''        t2'')
                $end_time=$t2
                }
            $start_time=$t1;
            $end_time=$t2;
            if( $t2 - $t1 < 3600) { $end_time = $t1 + 3600; }
            $power_on=1;
            }
        elsif($events->{$t}->{event_type} =~ /exists/ and $events->{$t}->{state} ne 'active')
            {
            $total_time_on += ($end_time - $start_time);
            $start_time=undef;
            $end_time=undef;
            $power_on=0;
            }
        }
    $total_time_on += ($end_time - $start_time);
    return (ceil($total_time_on/3600.0), 0.0);
    }

sub vm_subsection
    {
    my $vm=shift;
    my $flav=shift;
    my $t1=shift;
    my $t2=shift;
    my $flav=shift;
    my $total_hours=0;
    my $total_amt=0.00;
    my $rpt;
    my $amp=0.0;

    $rpt = "\\begin{table}[htbp]\n"
           ."\\begin{tabular}{l l r r }\n"
           ."VM Name & VM ID & Hours & Amt \\\\\n";

    foreach my $vm_id (sort keys $vm)
        {
        my $hours;
        my $amt;
        if($vm->{$vm_id}->{event_cnt}>0)
            {
            ($hours, $amt) = tally_hours2($vm->{$vm_id}->{events}, $flav);
            }
        else
            {
            $hours=0; $amt=0.0;
            }
        $total_hours+=$hours;
        #$total_amp=$total_amt+$amt;
        $rpt=$rpt."$vm->{$vm_id}->{name} & $vm_id & $hours & $amt\\\\\n";
        }
    $rpt=$rpt."VM Totals & & $total_hours &";
    $rpt=$rpt."\\end{tabular}\n"
             ."\\end{table}\n";
    return ($rpt, $total_amt);
    }

# Yes this combines both the project report and tallying up for the project report
# To split this would require similar work to be done in each
sub gen_project_reports
    {
    my $os_info = shift;
    my $flav = shift;
    my $proj_rpt_filename=shift;
    my $t1=shift;
    my $t2=shift;
    my $rpt;  # this is just a string containing the latex for the report.
    my $sub_total;
    my $total=0;

    $rpt="\\documentclass[10pt]{article}\n"
        ."\\usepackage [margin=0.5in] {geometry}\n"
        ."\\pagestyle{empty}\n"
        ."\\usepackage{tabularx}\n"
        ."\%\\usepackage{doublespace}\n"
        ."\%\\setstretch{1.2}\n"
        ."\\usepackage{ae}\n"
        ."\\usepackage[T1]{fontenc}\n"
        ."\\usepackage{CV}\n"
        ."\\begin{document}\n";

    my $proj=$os_info->{project};
    foreach my $proj_id (sort keys %{$proj})
        {
        $rpt= $rpt."\\begin{flushleft} \\textbf{\\textsc{OCX Project Report}}\\end{flushleft}\n"
             ."\\begin{flushleft} \\textsc{  Project: $proj->{$proj_id}->{name} id: $proj_id }\\end{flushleft}\n"
             ."\\flushleft{ \\textsc{     From: ".$t1."}}\n"
             ."\\flushleft{ \\textsc{     To: ".$t2."}}\n"
             ."\\newline\n";
        if($proj->{$proj_id}->{vm_cnt}>0)
            {
            my $sub_rpt;
            ($sub_rpt, $sub_total) = vm_subsection($proj->{$proj_id}->{VM},$flav,$t1,$t2);
            
            $rpt=$rpt.$sub_rpt;
            }
        else
            {
            $sub_total=0;
            }
        $total+=$sub_total;
        # vol_reports($proj->{$proj_id}->{Vol});
        # present a grand total
        $rpt=$rpt."";
        $rpt=$rpt."\\pagebreak\n";
        }
    $rpt=$rpt."\\end{document}";

    if(open(FP,">$proj_rpt_filename"))
        {
        print FP $rpt;
        }
    else
        {
        print STDERR "\n\n".$rpt."\n\n";
        }
    }



# get an openstack toke from keystone from the username/passowrd stored in 
# /etc/RBB/openstack.conf
sub get_unscoped_token
    {
    my $creds_filename=shift;
    my $creds;
    my $token;
    my $resp;

    $creds=YAML::XS::LoadFile($creds_filename);
    # my $keystone="https://kaizen.massopen.cloud:5000";
    my $url="https://engage1.massopen.cloud:5000/v3/auth/tokens";
    my $post_fields='{"auth": {"scope": {"unscoped": {}}, "identity": {"password": {"user": {"domain": {"id": "Default"}, "password": "'.$creds->{password}.'", "name": "'.$creds->{username}.'"}}, "methods": ["password"]}}}';
    my $post_fields='{"auth": {"identity": {"password": {"user": {"domain": {"name": "Default"}, "password": "'.$creds->{password}.'", "name": "'.$creds->{username}.'"}}, "methods": ["password"]}}}';
    # {"auth": {"scope": {"unscoped": {}}, "identity": {"password": {"user": {"domain": {"id": "Default"}, "password": "pass", "name": "mee"}}, "methods": ["password"]}}}

    my $curl=new WWW::Curl::Easy;
    #$curl->setopt(CURLOPT_URL,"https://engage1.massopen.cloud:5000/v3/auth/tokens");
    $curl->setopt(CURLOPT_URL,$url);
    $curl->setopt(WWW::Curl::Easy::CURLOPT_HTTPHEADER(),["Content-Type: application/json"]);
    $curl->setopt(CURLOPT_POSTFIELDS,$post_fields);
    $curl->setopt(CURLOPT_HEADER,1);
    $curl->setopt(CURLOPT_WRITEDATA, \$resp);
    $curl->perform();
    
    my $err=$curl->errbuf;
    my $json;    

    foreach my $l (split /\n/,$resp)
        { 
        if($l =~ /X-Subject-Token: ([a-zA-Z0-9\-_]+)/) { $token=$1; print "token: $1\n"; }
        $json=$l; #this is a simple stupid way of setting $json_str to the last element of the array.
        }

    #print $creds->{username}."\n";
    my $json_fields=from_json($json);
    #print Dumper($json_fields);
    my $ret;
    $ret->{user_id}=$json_fields->{token}->{user}->{id};
    $ret->{token}=$token;
    return $ret;
    }

sub get_scoped_token
    {
    my $unscoped_token=shift;
    my $project_id=shift;
    my $resp;
    my $ret;

    my $url="https://engage1.massopen.cloud:5000/v3/auth/tokens";
    my $post_fields='{"auth": {"scope": {"project": {"id": "'.$project_id.'"}}, "identity": {"token": {"id": "'.$unscoped_token.'"}, "methods": ["token"]}}}';

    my $curl=new WWW::Curl::Easy;
    $curl->setopt(CURLOPT_URL,$url);
    $curl->setopt(WWW::Curl::Easy::CURLOPT_HTTPHEADER(),["Content-Type: application/json"]);
    $curl->setopt(CURLOPT_POSTFIELDS,$post_fields);
    $curl->setopt(CURLOPT_HEADER,1);
    $curl->setopt(CURLOPT_WRITEDATA, \$resp);
    $curl->perform();

    my $err=$curl->errbuf;
    my $json;

    foreach my $l (split /\n/,$resp)
        {
        if($l =~ /X-Subject-Token: ([a-zA-Z0-9\-_]+)/) { $ret->{token}=$1; print "token: $1\n"; }
        $json=$l; #this is a simple stupid way of setting $json_str to the last element of the array.
        }
    my $json_fields=from_json($json);
    $ret->{catalog}=$json_fields->{token}->{catalog};
    #$ret->{catalog}=from_json($json);
    return $ret;
    }
#using previousily obtained user_id and token, get the projects
#
sub get_os_projects
    {
    my $os_info=shift;
    my $resp;
    my $url="https://engage1.massopen.cloud:5000/v3/users/".$os_info->{user_id}."/projects";
    my $json;

    
    my $curl=new WWW::Curl::Easy;
    $curl->setopt(CURLOPT_URL,$url);
    $curl->setopt(WWW::Curl::Easy::CURLOPT_HTTPHEADER(),["X-Auth-Token: $os_info->{token}"]);
    $curl->setopt(CURLOPT_HEADER,1); 
    $curl->setopt(CURLOPT_WRITEDATA, \$resp);
    $curl->perform();
    
    my $err=$curl->errbuf;
    my @resp=(split /\n/,$resp);
    my $json_fields=from_json($resp[-1]);
    foreach my $p (@{$json_fields->{projects}})
        {
        if( $p->{name} eq 'admin')
            {
            $os_info->{admin}->{id}=$p->{id};
            $os_info->{admin}->{domain}=$p->{domain_id};
            }
        else
            {
            $os_info->{project}->{$p->{id}}->{name}=$p->{name};
            $os_info->{project}->{$p->{id}}->{domain}=$p->{domain_id};
            }
        }
    return $os_info;
    }


# This needs to be generalized
# currently only accepts the admin token;
sub get_os_flavors
    {
    my $os_info=shift;
    my $endpt=find_in_catalog("nova",$os_info->{admin}->{catalog});
    my $url=$endpt."/flavors/detail";
    my $resp;
    my $flavor;

    if(!(exists $os_info->{admin}->{token}))
        {
        warn "get os_flavors(...) needs to be generalized to take any token\n";
        return undef;
        }

    my $curl=new WWW::Curl::Easy;
    $curl->setopt(CURLOPT_URL,$url);
    $curl->setopt(WWW::Curl::Easy::CURLOPT_HTTPHEADER(),["X-Auth-Token: $os_info->{admin}->{token}"]);
    $curl->setopt(CURLOPT_WRITEDATA, \$resp);
    $curl->perform();

    my $err=$curl->errbuf;
    my $flavor_array=from_json($resp);
    foreach my $f (@{$flavor_array->{flavors}})
        {
        $flavor->{$f->{name}}->{id}=$f->{id};
        $flavor->{$f->{name}}->{vcpus}=$f->{vcpus};
        $flavor->{$f->{name}}->{ram}=$f->{ram};
        $flavor->{$f->{name}}->{disk}=$f->{disk};
        }
    return $flavor;
    }

sub get_all_projects
    {
    my $os_info=shift;
    my $url="https://engage1.massopen.cloud:5000/v3/projects";
    my $resp;
    
    if( not (exists $os_info->{admin}->{token} ) )
        {
        my $tac=get_scoped_token($os_info->{token},$os_info->{admin}->{id});
        $os_info->{admin}->{token}=$tac->{token};
        $os_info->{admin}->{catalog}=$tac->{catalog};
        }
    
    my $curl=new WWW::Curl::Easy;
    $curl->setopt(CURLOPT_URL,$url);
    $curl->setopt(WWW::Curl::Easy::CURLOPT_HTTPHEADER(),["X-Auth-Token: $os_info->{admin}->{token}"]);
    $curl->setopt(CURLOPT_WRITEDATA, \$resp);
    $curl->perform();
    
    my $json_fields = from_json($resp);
    foreach my $p (@{$json_fields->{projects}})
        {
        $os_info->{project}->{$p->{id}}->{name}=$p->{name};
        $os_info->{project}->{$p->{id}}->{domain}=$p->{domain_id};
        }
    return $os_info;
    }

# get all volumes

sub find_in_catalog
    {
    my $name=shift;
    my $catalog=shift;
    my $endpoint;

    #should reorganize catalog to make finding a particular service faster
    foreach my $entry (@{$catalog})
        {
        if($entry->{name} eq $name)
            {
            foreach my $endpt (@{$entry->{endpoints}})
                {
                if($endpt->{interface} eq 'public')
                    {
                    return $endpt->{url};
                    }
                }
            }
        }

    return $endpoint;
    }

#  use panko this to find the instances.
#  This needs to be stored in a dababase.
sub get_panko_data
    {
    my $os_info=shift;
    my $endpt=find_in_catalog("panko",$os_info->{admin}->{catalog});
    my $query_string='?q.field=all_tenants&q.op=eq&q.value=True';
    my $url = $endpt."/v2/events".$query_string;

    # print "URL: $url\n";
    my $curl=new WWW::Curl::Easy;
    my $resp;
    $curl->setopt(CURLOPT_URL,$url);
    $curl->setopt(WWW::Curl::Easy::CURLOPT_HTTPHEADER(),["X-Auth-Token: $os_info->{admin}->{token}"]);
    $curl->setopt(CURLOPT_WRITEDATA, \$resp);
    $curl->perform();

    #print "\n\n".$resp."\n\n";
    my $fields=from_json $resp;
    my $rec;
    for my $event (@$fields)
        {
        if($event->{event_type}=~/compute\.instance/)
            {
            $rec=undef;
            $rec->{event_type}=$event->{event_type};
            # print Dumper $event;
            foreach my $trait (@{$event->{traits}})
                {
                if   ($trait->{name} eq  'project_id')             { $rec->{project_id}  = $trait->{value}; }
                elsif($trait->{name} eq  'instance_id')            { $rec->{instance_id} = $trait->{value}; }
                elsif($trait->{name} eq  'audit_period_beginning') { $rec->{start_ts}    = $trait->{value}; }
                elsif($trait->{name} eq  'audit_period_ending')    { $rec->{end_ts}      = $trait->{value}; }
                elsif($trait->{name} eq  'state')                  { $rec->{state}       = $trait->{value}; }
                elsif($trait->{name} eq  'instance_type')          { $rec->{flavor}      = $trait->{value}; }
                elsif($trait->{name} eq  'vcpus')                  { $rec->{vcpus}       = $trait->{value}; }
                elsif($trait->{name} eq  'memory_mb')              { $rec->{mem}         = $trait->{value}; }
                elsif($trait->{name} eq  'disk_gb')                { $rec->{disk_gb}     = $trait->{value}; }
                }
            $os_info->{project}->{$rec->{project_id}}->{vm_cnt}=1;
            $os_info->{project}->{$rec->{project_id}}->{VM}->{$rec->{instance_id}}->{event_cnt}=1;

            $os_info->{project}->{$rec->{project_id}}->{VM}->{$rec->{instance_id}}->{events}->{$rec->{start_ts}}->{end_ts}=$rec->{end_ts};
            $os_info->{project}->{$rec->{project_id}}->{VM}->{$rec->{instance_id}}->{events}->{$rec->{start_ts}}->{state}=$rec->{state};
            $os_info->{project}->{$rec->{project_id}}->{VM}->{$rec->{instance_id}}->{events}->{$rec->{start_ts}}->{flavor}=$rec->{flavor};
            $os_info->{project}->{$rec->{project_id}}->{VM}->{$rec->{instance_id}}->{events}->{$rec->{start_ts}}->{vcpus}=$rec->{vcpus};
            $os_info->{project}->{$rec->{project_id}}->{VM}->{$rec->{instance_id}}->{events}->{$rec->{start_ts}}->{mem}=$rec->{mem}/1024;
            $os_info->{project}->{$rec->{project_id}}->{VM}->{$rec->{instance_id}}->{events}->{$rec->{start_ts}}->{disk_gb}=$rec->{disk_gb};
            $os_info->{project}->{$rec->{project_id}}->{VM}->{$rec->{instance_id}}->{events}->{$rec->{start_ts}}->{event_type}=$rec->{event_type};
            }
        else 
            {
            print STDERR "---> Unhandeled event: $event->{event_type}\n";
            }    
        }
    #print Dumper{@$fields};
    #print Dumper{%$os_info};
    #exit;
    return $os_info;
    }

sub get_volumens_from_panko
    {

    }

sub login_to_admin_acct
    {
    my $os_info=shift;

    return $os_info;
    }

my $os_info=get_unscoped_token("/Users/Rob/.RBB/acct.yaml");
print "1 -->\n";
$os_info=get_os_projects($os_info);
print "2 -->\n";
$os_info=get_all_projects($os_info);
print "3 -->\n";
my $flavors=get_os_flavors($os_info);
print "4 -->\n";
$os_info=get_panko_data($os_info);
print "5 -->\n";
gen_project_reports($os_info,$flavors,"/Users/Rob/billing/test_rpt.tex","01-APR-2018 00:00:00", "03-APR-2018 23:59:59");



#$os_info=get_data_from_gnocchi($os_info);
#print "A-->\n\n";
print Dumper{%$os_info}; 
exit;


# stage1 define what has been used  
# These must be first
my $proj=read_projects("data/01-03-APR-2012/cloud_tenants.csv");
my $flav=read_flavors("data/01-03-APR-2012/flavors.csv");

# This set can be in any order
$proj=read_vms($proj,"data/01-03-APR-2012/vms.csv");
$proj=read_vol($proj,"data/01-03-APR-2012/vol.csv");

#  This is not relating instances to usage statistics yet.
sub get_gnocchi_data
    {
    my $os_info=shift;
    my $proj=shift;
    my $start_ts=shift;
    my $end_ts=shift;

    #print Dumper {%$proj};

    foreach my $proj_id (sort keys %$proj)
        {
        if($proj->{$proj_id}->{vm_cnt}>0)
            {
            my $vm=$proj->{$proj_id}->{VM};
            foreach my $vm_id (sort keys %$vm)
                {
                #print "proj id: $proj_id, vm id: $vm_id\n";
                my $endpt=find_in_catalog("gnocchi",$os_info->{admin}->{catalog});
                #print "URL: ".$url."\n";
                
                # This will get the metric definitions
                my $url = $endpt."/v1/metric";
                #my $url = $endpt."/v1/aggregation/resource/instance/metric/memory.usage?granularity=300&start=-30+days";

                print "URL: $url\n";
#exit;
                my $curl=new WWW::Curl::Easy;
                my $resp;
                my $post_fields = "{}";
                $curl->setopt(CURLOPT_URL,$url);
                $curl->setopt(WWW::Curl::Easy::CURLOPT_HTTPHEADER(),["X-Auth-Token: $os_info->{admin}->{token}"]);
                $curl->setopt(CURLOPT_POSTFIELDS,$post_fields);
                $curl->setopt(CURLOPT_WRITEDATA, \$resp);
                $curl->perform();

                #print Dumper{$resp};
                my $json_fields=from_json($resp);
                #print "--->\n\n";
                #print Dumper{$json_fields};
                #print "-\n\n--->\n\n";
                #my $yaml_fields=YAML::XS::Load $resp;
# exit;
                }
            }
        }
    return $proj;   
    }

# get the time dependent data our
# $proj = get_gnocchi_data($os_info,$proj,"01-MAR-2018 00:00:00","19-MAR-2018 00:00:00");

# process the metrics (metric_rollup table)
# Note this is rolled up to the hour.
#$proj = get_metrics_data($proj,"data/01-19-MAR-2012/metrics.csv","01-MAR-2018 00:00:00","18-MAR-2018 23:59:59");

#gen_project_reports($proj,$flav,"ProjectRpts.tex","01-MAR-2018 00:00:00","19-MAR-2018 00:00:00");

#print "\n\n---- ------- ------\n\n";
print Dumper{%$proj};
#print "\n\n---- ------- ------\n\n";
#print Dumper{%$flav};
exit;

# $10/terabyte
# price for flavor

# 2 reports
#   cost at our proposed pricing
#   cost at amazon's pricing

# yes this is metric rollup
#sub read_metrics
#    {
#    }
