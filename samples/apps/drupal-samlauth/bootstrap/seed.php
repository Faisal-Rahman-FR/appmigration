<?php
use Drupal\user\Entity\User;
use Drupal\node\Entity\Node;

$networkModules = array_values(array_filter(['update','automated_cron'], static fn(string $name): bool => \Drupal::moduleHandler()->moduleExists($name)));
if ($networkModules) \Drupal::service('module_installer')->uninstall($networkModules);
$users = json_decode(file_get_contents('/opt/demo/users.json'), TRUE, 512, JSON_THROW_ON_ERROR);
foreach ($users as $data) {
  $existing = \Drupal::entityTypeManager()->getStorage('user')->loadByProperties(['name'=>$data['uid']]);
  if (!$existing) {
    User::create(['name'=>$data['uid'], 'mail'=>$data['mail'], 'status'=>1, 'pass'=>bin2hex(random_bytes(32))])->save();
  }
}
foreach (['Synthetic Research News'=>'A seeded synthetic article for editor demonstrations.', 'Lab Safety Briefing'=>'Synthetic content only; no personal student or employee records.'] as $title=>$body) {
  $existing = \Drupal::entityTypeManager()->getStorage('node')->loadByProperties(['title'=>$title]);
  if (!$existing) Node::create(['type'=>'article', 'title'=>$title, 'uid'=>1, 'status'=>1, 'body'=>['value'=>$body,'format'=>'plain_text']])->save();
}
\Drupal::state()->set('demo_portal.seeded', TRUE);
